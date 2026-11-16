# Folder script

`carnet-folder.sh` sends every car photo in a folder to the CarNET API and saves the answers: one JSON file per photo and one CSV file with a row per car.

It keeps to your key's limits by itself. Every API answer says how many requests the key has left, so the script never needs to be told your plan:

- It sends no faster than your key allows per second.
- When the key's daily or monthly limit runs out, it stops and tells you when the limit renews. With `--wait`, it waits and carries on.
- Running it again carries on where it stopped. Photos that already have an answer are never sent again.

## What you need

- **bash, curl and jq.** macOS 15 or later has all three. On older macOS, install jq with `brew install jq`. On Debian or Ubuntu: `sudo apt install curl jq`. On Windows, use WSL.
- **A CarNET API key.** Get a free trial key (300 requests) at [carnet.ai](https://carnet.ai/#pricing-block). You don't need a key for CarNET Server.

## Run it

```sh
curl -O https://raw.githubusercontent.com/OneStar-dev/CarNET.ai.samples/main/shell/carnet-folder.sh
chmod +x carnet-folder.sh

export CARNET_API_KEY=your-key
./carnet-folder.sh ~/Pictures/cars
```

You'll see one line per photo:

```text
[1/5] alfa.jpg: Alfa Romeo 156 I facelift (2002-2003) 98.1%, Black, front-right
[2/5] dacia.jpg: Dacia Sandero II (2012-2016) 85.8%, Red, back-left
[3/5] volvo.jpg: Volvo XC60 I facelift (2013-2017) 99.9%, Silver, front-left
[4/5] garden.jpg: no car recognized
[5/5] broken.jpg: Error decoding image

Sent 5 photos: 3 with a car, 1 without a car, 1 the API could not read.
Answers: /Users/you/Pictures/cars/carnet-results (results.csv has one row per car)
The key has 94 of 100 requests left until 2026-11-17 11:46 UTC.
```

It sends JPEG, PNG, WEBP, GIF, BMP and TIFF files of up to 12 MB. Convert other formats, such as HEIC, to JPEG first.

## What you get

The answers go to `carnet-results` inside the folder (change it with `--out`):

- **`<photo>.json`** for each photo: the API's full answer, with the top 3 makes, models and generations, colors and angles, and where the car is in the photo. The [API description](https://app.swaggerhub.com/apis-docs/CarNET.ai/MMG/2.1) explains every field.
- **`results.csv`** for all photos, rebuilt at each run:

| Column | Example | Meaning |
|---|---|---|
| `photo` | `alfa.jpg` | The photo's path inside the folder |
| `car` | `1` | Which car in the photo (most photos have one) |
| `status` | `recognized` | `recognized`, `no car` or `error` |
| `make`, `model`, `generation` | `Alfa Romeo`, `156`, `I facelift` | The most likely make, model and generation |
| `years` | `2002-2003` | The generation's production years |
| `probability` | `0.9806` | How sure the recognition is, from 0 to 1 |
| `color` | `Black` | The most likely body color |
| `angle` | `front-right` | The side the photo was taken from |
| `box_left` … `box_bottom` | `0.103` | Where the car is, as fractions of the photo's width and height |
| `error` | `Error decoding image` | Why the API could not read the photo |

## How it keeps to your limits

Each photo sent is one request, whether or not it shows a car. The API answers every request with the key's limits:

| Header | Meaning |
|---|---|
| `X-Rate-Limit-Remaining`, `X-Rate-Limit-Reset` | Requests left this second, and when the next second starts |
| `X-Quota-Remaining`, `X-Quota-Reset` | Requests left today or this month, and when the count starts again |

Reset times are Unix times in milliseconds. A plan without a per-second or a daily limit doesn't send that pair.

The script reads these after each photo. When this second's requests are used up, it waits for the next second, so the API doesn't have to refuse anything. When the daily or monthly limit is used up, it stops with exit code 3:

```text
The key's limit of 100 requests is used up. It renews at 2026-11-17 11:46 UTC.
Run the same command again then to carry on, or add --wait to let it wait.
```

If another program uses the same key, the API may refuse a request with HTTP 429. The script handles that the same way: it waits and sends the photo again, or stops when the limit is used up.

A network or server error is tried again after 2, 8 and 18 seconds, so a photo can take up to 4 requests. A photo that still gets no answer is sent again at the next run. The script never sends a retry once the API has said the limit is used up.

## Options

| Option | Meaning |
|---|---|
| `-o`, `--out DIR` | Where the answers go. Default: `FOLDER/carnet-results` |
| `-r`, `--recursive` | Include photos in subfolders. Answers keep the same subfolders. |
| `-w`, `--wait` | When the limit runs out, wait until it renews and carry on |
| `--region NA` | Use the network trained for North America. Default: worldwide |
| `--params QUERY` | Other API parameters, such as `box_select=all` to recognize every car in a photo, not only the one in the centre |
| `--api URL` | The API's address. Default: `https://api.carnet.ai/v2/mmg/detect` |

Exit codes:

- `0`: finished. Photos over 12 MB are skipped and listed.
- `1`: some photos got no answer, a folder could not be read, or an error stopped the run (for example, the key was refused).
- `2`: wrong options.
- `3`: stopped because the key's limit ran out.

To send a photo again, delete its `.json` file and run the script.

## CarNET Server

[CarNET Server](https://carnet.ai/on-premise) answers the same requests on your own machine, with no key and no limits:

```sh
./carnet-folder.sh --api http://YOUR-SERVER:50052/detect ~/Pictures/cars
```

## Run it every night

Keep the key in a file only you can read, then add a line to your crontab (`crontab -e`). This one runs at 02:00 and waits whenever the limit runs out. With `--wait`, a run with many photos can last until the next night, so `flock` (Linux) skips the new run while the old one is still going; two runs on the same folder would send the same photos twice:

```sh
echo 'your-key' > ~/.carnet-key && chmod 600 ~/.carnet-key
```

```cron
0 2 * * * CARNET_API_KEY=$(cat ~/.carnet-key) flock -n /tmp/carnet-folder.lock /path/to/carnet-folder.sh --wait /data/photos >> ~/carnet-folder.log 2>&1
```

## Tests

`test/run-tests.sh` runs the script against `test/fake_api.py`, a local stand-in for the API, so it sends no real requests. It needs python3.
