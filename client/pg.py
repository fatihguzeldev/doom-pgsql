import ctypes as C
from collections import deque
from ctypes.util import find_library
from functools import lru_cache
from pathlib import Path
from subprocess import check_output


COMMAND_OK = 1
TUPLES_OK = 2
PIPELINE_SYNC = 10


class SqlError(RuntimeError):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


@lru_cache(maxsize=1)
def libpq():
    library = find_library('pq')
    if library is None:
        directory = Path(check_output(['pg_config', '--libdir'], text=True).strip())
        library = next(str(path) for path in (directory / 'libpq.dylib', directory / 'libpq.so') if path.exists())
    lib = C.CDLL(library)
    pointer, string, number = C.c_void_p, C.c_char_p, C.c_int
    values = C.POINTER(string)
    signatures = {
        'PQconnectdb': (pointer, string),
        'PQstatus': (number, pointer),
        'PQfinish': (None, pointer),
        'PQerrorMessage': (string, pointer),
        'PQsocket': (number, pointer),
        'PQexecParams': (pointer, pointer, string, number, pointer, values, pointer, pointer, number),
        'PQprepare': (pointer, pointer, string, string, number, pointer),
        'PQsendQueryPrepared': (number, pointer, string, number, values, pointer, pointer, number),
        'PQsetnonblocking': (number, pointer, number),
        'PQenterPipelineMode': (number, pointer),
        'PQpipelineSync': (number, pointer),
        'PQflush': (number, pointer),
        'PQconsumeInput': (number, pointer),
        'PQisBusy': (number, pointer),
        'PQgetResult': (pointer, pointer),
        'PQresultStatus': (number, pointer),
        'PQresultErrorMessage': (string, pointer),
        'PQresultErrorField': (string, pointer, number),
        'PQntuples': (number, pointer),
        'PQnfields': (number, pointer),
        'PQgetisnull': (number, pointer, number, number),
        'PQgetlength': (number, pointer, number, number),
        'PQgetvalue': (pointer, pointer, number, number),
        'PQclear': (None, pointer),
    }
    for name, (result, *arguments) in signatures.items():
        function = getattr(lib, name)
        function.restype = result
        function.argtypes = arguments
    return lib


def parameters(values):
    return (C.c_char_p * len(values))(*(None if value is None else str(value).encode() for value in values))


def integer(value):
    if value is None or len(value) not in (2, 4, 8):
        raise ValueError('invalid PostgreSQL integer field')
    return int.from_bytes(value, 'big', signed=True)


class Connection:
    def __init__(self, options=b''):
        self.lib = libpq()
        self.conn = self.lib.PQconnectdb(options)
        self.queue = deque()
        self.result = None
        self.wants_write = False
        if not self.conn:
            raise ConnectionError('libpq could not allocate a connection')
        if self.lib.PQstatus(self.conn) != 0:
            message = self.error()
            self.close()
            raise ConnectionError(message)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    @property
    def fd(self):
        return self.lib.PQsocket(self.conn)

    @property
    def pending(self):
        return len(self.queue)

    def error(self):
        return self.lib.PQerrorMessage(self.conn).decode(errors='replace').strip()

    def close(self):
        if self.conn:
            self.lib.PQfinish(self.conn)
            self.conn = None

    def _fields(self, result):
        lib = self.lib
        if lib.PQntuples(result) != 1:
            raise ValueError('expected one result row')
        return tuple(None if lib.PQgetisnull(result, 0, i) else
                     C.string_at(lib.PQgetvalue(result, 0, i), lib.PQgetlength(result, 0, i))
                     for i in range(lib.PQnfields(result)))

    def _sql_error(self, result):
        text = self.lib.PQresultErrorMessage(result).decode(errors='replace').strip()
        code = self.lib.PQresultErrorField(result, ord('C')) or b''
        return SqlError(text or 'unexpected PostgreSQL result', code.decode())

    def _statement(self, result):
        if not result:
            raise ConnectionError(self.error())
        try:
            status = self.lib.PQresultStatus(result)
            if status == COMMAND_OK:
                return ()
            if status == TUPLES_OK:
                return self._fields(result)
            raise self._sql_error(result)
        finally:
            self.lib.PQclear(result)

    def execute(self, query, *values):
        return self._statement(self.lib.PQexecParams(self.conn, query, len(values), None,
                                                     parameters(values), None, None, 1))

    def prepare(self, query):
        self._statement(self.lib.PQprepare(self.conn, b'game_lane', query, 0, None))

    def start_pipeline(self):
        if self.lib.PQsetnonblocking(self.conn, 1) != 0 or not self.lib.PQenterPipelineMode(self.conn):
            raise ConnectionError(self.error())

    def _flush(self):
        status = self.lib.PQflush(self.conn)
        if status < 0:
            raise ConnectionError(self.error())
        self.wants_write = status == 1

    def send(self, tag, *values):
        if not self.lib.PQsendQueryPrepared(self.conn, b'game_lane', len(values),
                                            parameters(values), None, None, 1):
            raise ConnectionError(self.error())
        if not self.lib.PQpipelineSync(self.conn):
            raise ConnectionError(self.error())
        self.queue.append(tag)
        self._flush()

    def poll(self, readable=False, writable=False):
        if readable and not self.lib.PQconsumeInput(self.conn):
            raise ConnectionError(self.error())
        if self.wants_write and (writable or readable):
            self._flush()
        completed = []
        separated = False
        while self.queue and not self.lib.PQisBusy(self.conn):
            result = self.lib.PQgetResult(self.conn)
            if not result:
                if separated:
                    break
                separated = True
                continue
            separated = False
            try:
                status = self.lib.PQresultStatus(result)
                if status == PIPELINE_SYNC:
                    # The result before Sync alone does not acknowledge a commit.
                    if self.result is None:
                        raise ConnectionError('received Sync without a statement result')
                    completed.append((self.queue.popleft(), self.result))
                    self.result = None
                elif status == TUPLES_OK:
                    self.result = self._fields(result)
                elif status == COMMAND_OK:
                    self.result = ()
                else:
                    self.result = self._sql_error(result)
            finally:
                self.lib.PQclear(result)
        return completed
