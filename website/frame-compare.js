(() => {
  const figure = document.querySelector(".frame-compare");
  const shades = figure.querySelector(".frame-shades");
  const seam = figure.querySelector(".frame-seam");
  const controls = figure.querySelector(".frame-controls");
  const slider = figure.querySelector("#frame-split");

  function updateSplit() {
    const framePercent = slider.valueAsNumber;
    const shadePercent = 100 - framePercent;
    figure.style.setProperty("--frame-split", `${framePercent}%`);
    seam.hidden = framePercent === 0 || shadePercent === 0;

    let valueText = `${framePercent}% frame, ${shadePercent}% shade data`;
    if (framePercent === 0) valueText = "shade data only";
    else if (shadePercent === 0) valueText = "frame only";
    slider.setAttribute("aria-valuetext", valueText);
  }

  function enableComparison() {
    if (!shades.naturalWidth) return;
    updateSplit();
    shades.hidden = false;
    controls.hidden = false;
    slider.addEventListener("input", updateSplit);
  }

  if (shades.complete) enableComparison();
  else shades.addEventListener("load", enableComparison, { once: true });
})();
