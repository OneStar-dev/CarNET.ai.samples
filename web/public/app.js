// The page: takes a photo (dropped, chosen, pasted or an example), shrinks it, sends it to this site's server
// (POST /api/recognize, which adds the API key) and shows the cars the CarNET API found.

const LONG_SIDE = 2048; // larger photos are shrunk to this many pixels on their long side before sending (see README)
const QUALITY = 0.85; // JPEG quality of a shrunk photo
const MAX_BYTES = 12 * 1024 * 1024; // the API takes photos up to 12 MB
const API_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/bmp', 'image/tiff']; // sent as they are

const $ = (id) => document.getElementById(id);
let busy = false;
let shownUrl = null;

// --- The ways to give a photo -----------------------------------------------------------------------------------

$('file').addEventListener('change', () => {
  const file = $('file').files[0];
  $('file').value = ''; // so the same file can be chosen again
  if (file) recognize(file);
});

// A photo can be dropped anywhere on the page.
document.addEventListener('dragover', (event) => {
  event.preventDefault();
  $('drop').classList.add('over');
});
document.addEventListener('dragleave', (event) => {
  if (!event.relatedTarget) $('drop').classList.remove('over');
});
document.addEventListener('drop', (event) => {
  event.preventDefault();
  $('drop').classList.remove('over');
  const file = event.dataTransfer.files[0];
  if (file) recognize(file);
  else say('Drop a photo file from your computer.', true);
});

document.addEventListener('paste', (event) => {
  const file = event.clipboardData?.files[0];
  if (!file) return;
  event.preventDefault();
  recognize(file);
});

for (const button of document.querySelectorAll('[data-photo]')) {
  button.addEventListener('click', async () => {
    try {
      const response = await fetch(button.dataset.photo);
      if (!response.ok) throw new Error();
      recognize(await response.blob());
    } catch {
      say('Could not load the example photo.', true);
    }
  });
}

// --- Sending the photo ---------------------------------------------------------------------------------------------

async function recognize(file) {
  if (busy) return;
  setBusy(true);
  say('Recognizing…');
  try {
    const { photo, url } = await prepare(file);
    showPhoto(url);
    let response;
    try {
      response = await fetch('api/recognize', {
        method: 'POST',
        headers: { 'Content-Type': 'application/octet-stream' },
        body: photo,
        signal: AbortSignal.timeout(90_000),
      });
    } catch (error) {
      if (error.name === 'TimeoutError') throw new Error("This site's server took too long to answer. Try again.");
      throw new Error("Could not reach this site's server. Check your connection and try again.");
    }
    let answer;
    try {
      answer = await response.json();
    } catch {
      throw new Error(`This site's server gave an unexpected answer (HTTP ${response.status}).`);
    }
    if (!response.ok) throw new Error(answer.error || `This site's server answered with HTTP ${response.status}.`);
    showAnswer(answer);
  } catch (error) {
    say(error.message, true);
  } finally {
    setBusy(false);
  }
}

// Shrinks a large photo to LONG_SIDE pixels on its long side, as a JPEG: a quarter of a phone photo's upload.
// The browser turns the photo upright (from the camera's rotation flag) as it draws it, so the JPEG is upright.
// A smaller photo in a format the API takes goes as it is; other formats the browser can open become a JPEG.
async function prepare(file) {
  const url = URL.createObjectURL(file);
  const image = new Image();
  image.src = url;
  try {
    await image.decode();
  } catch {
    // This browser can't open the file (HEIC or TIFF in most browsers). Send it anyway: the API says if it can't read it.
    URL.revokeObjectURL(url);
    if (file.size > MAX_BYTES) throw new Error('The photo is larger than 12 MB.');
    return { photo: file, url: null };
  }
  const scale = Math.min(1, LONG_SIDE / Math.max(image.naturalWidth, image.naturalHeight));
  if (scale === 1 && API_TYPES.includes(file.type) && file.size <= MAX_BYTES) return { photo: file, url };

  const canvas = document.createElement('canvas');
  canvas.width = Math.round(image.naturalWidth * scale);
  canvas.height = Math.round(image.naturalHeight * scale);
  canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
  URL.revokeObjectURL(url);
  const photo = await new Promise((done) => canvas.toBlob(done, 'image/jpeg', QUALITY));
  if (!photo) throw new Error('Could not prepare the photo.');
  return { photo, url: URL.createObjectURL(photo) };
}

// --- Showing the answer ----------------------------------------------------------------------------------------------

function showPhoto(url) {
  if (shownUrl) URL.revokeObjectURL(shownUrl);
  shownUrl = url;
  $('result').hidden = false;
  $('photo').hidden = !url;
  if (url) $('photo').src = url;
  else $('photo').removeAttribute('src');
  $('boxes').replaceChildren();
  $('cars').replaceChildren();
  $('answer').textContent = '';
}

// A car is a detection that comes with a make and model (mmg, or mm when only those were asked for).
function showAnswer(answer) {
  $('answer').textContent = JSON.stringify(answer, null, 2);
  if (answer.is_success !== true) {
    say(answer.error?.message || 'The recognition service could not read this photo.', true);
    return;
  }
  const cars = (answer.detections || []).filter((detection) => (detection.mmg || detection.mm || []).length > 0);
  const time = answer.meta?.time ? ` The API took ${answer.meta.time.toFixed(2)} s.` : '';
  if (cars.length === 0) say(`No car recognized in this photo.${time}`);
  else say(`${cars.length === 1 ? 'Found 1 car' : `Found ${cars.length} cars`}.${time}`);

  cars.forEach((car, i) => {
    const box = element('div', 'box');
    box.append(element('span', null, String(i + 1)));
    box.style.left = `${car.box.tl_x * 100}%`;
    box.style.top = `${car.box.tl_y * 100}%`;
    box.style.width = `${(car.box.br_x - car.box.tl_x) * 100}%`;
    box.style.height = `${(car.box.br_y - car.box.tl_y) * 100}%`;
    $('boxes').append(box);

    const [best, ...others] = car.mmg || car.mm;
    const details = [`${percent(best.probability)} sure`];
    if (car.color?.length) details.push(car.color[0].name);
    if (car.angle?.length) details.push(`${car.angle[0].name} view`);
    const item = element('li');
    const title = element('p', 'name', carName(best));
    if (best.years) title.append(' ', element('span', 'years', best.years));
    item.append(title, element('p', 'details', details.join(' · ')));
    if (others.length) {
      item.append(element('p', 'others', `Also possible: ${others.map((o) => `${carName(o)} (${percent(o.probability)})`).join(', ')}`));
    }
    $('cars').append(item);
  });
}

const carName = (guess) => [guess.make_name, guess.model_name, guess.generation_name].filter(Boolean).join(' ');
const percent = (p) => `${Math.round(p * 1000) / 10}%`;

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function say(text, isError = false) {
  $('status').textContent = text;
  $('status').classList.toggle('error', isError);
}

function setBusy(value) {
  busy = value;
  document.body.classList.toggle('busy', value);
  $('file').disabled = value;
  for (const button of document.querySelectorAll('[data-photo]')) button.disabled = value;
}
