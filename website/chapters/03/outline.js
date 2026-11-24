const outline = document.querySelector(".chapter-outline");
const toggle = outline.querySelector("button");
const label = toggle.querySelector("span");
const sections = Array.from(outline.querySelectorAll("a"), link => ({
  link,
  heading: document.getElementById(link.hash.slice(1)),
}));

let currentLink;
let updateFrame = 0;

function updateSection() {
  updateFrame = 0;
  const offset = parseFloat(getComputedStyle(sections[0].heading).scrollMarginBlockStart);
  let section = sections[0];

  for (const candidate of sections) {
    if (candidate.heading.getBoundingClientRect().top > offset + 1) break;
    section = candidate;
  }

  if (window.scrollY > 0 && Math.ceil(window.scrollY + window.innerHeight) >= document.documentElement.scrollHeight) {
    section = sections.at(-1);
  }

  if (section.link === currentLink) return;
  currentLink?.removeAttribute("aria-current");
  currentLink = section.link;
  currentLink.setAttribute("aria-current", "location");
  label.textContent = currentLink.textContent;
}

function queueUpdate() {
  if (!updateFrame) updateFrame = requestAnimationFrame(updateSection);
}

function isExpanded() {
  return toggle.getAttribute("aria-expanded") === "true";
}

function closeMenu() {
  if (isExpanded()) toggle.setAttribute("aria-expanded", "false");
}

toggle.addEventListener("click", () => {
  toggle.setAttribute("aria-expanded", String(!isExpanded()));
});

outline.addEventListener("keydown", event => {
  if (event.key !== "Escape" || !isExpanded()) return;
  closeMenu();
  toggle.focus();
});

outline.addEventListener("focusout", event => {
  if (event.relatedTarget && !outline.contains(event.relatedTarget)) closeMenu();
});

document.addEventListener("click", event => {
  if (!outline.contains(event.target) || event.target.closest(".chapter-outline-links a")) closeMenu();
});

window.addEventListener("scroll", queueUpdate, { passive: true });
window.addEventListener("resize", () => {
  if (!toggle.getClientRects().length) closeMenu();
  queueUpdate();
});
window.addEventListener("hashchange", queueUpdate);
window.addEventListener("pageshow", queueUpdate);
document.fonts.ready.then(queueUpdate);

toggle.hidden = false;
updateSection();
