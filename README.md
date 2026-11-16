# CarNET API code samples

The [CarNET API](https://carnet.ai/make-model-recognition-api) recognizes a car's make, model and generation from a photo, together with its body color and the angle it was photographed from. These samples show how to use it, from a one-line request to complete apps you can build and run.

| Sample | What it does | Language |
|---|---|---|
| [Folder script](shell/) | Recognizes every photo in a folder, keeping to your key's limits, and writes a CSV | bash, curl, jq |
| [Micro website](web/) | Example photos plus drop, pick or paste a photo, and see the result with a box around each car | Node.js, HTML |
| [iOS app](ios/) | Take or choose a photo, shrink it, and see the result with a box around each car | Swift, SwiftUI |
| [Android app](android/) | The same on Android | Kotlin, Jetpack Compose |

## Get a key

Get a free trial key (300 requests) at [carnet.ai](https://carnet.ai/#pricing-block), or pick a plan there.

## One request

Send the photo's bytes in the request body and your key in the `api-key` header:

```sh
curl -X POST "https://api.carnet.ai/v2/mmg/detect?features=mmg,color,angle" \
  -H "api-key: $CARNET_API_KEY" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @car.jpg
```

The answer (shortened):

```json
{
  "is_success": true,
  "detections": [
    {
      "box": { "tl_x": 0.103, "tl_y": 0.2237, "br_x": 0.8801, "br_y": 0.7721 },
      "mmg": [
        { "make_name": "Porsche", "model_name": "Taycan", "generation_name": "I facelift", "years": "2024-", "probability": 0.997 }
      ],
      "color": [ { "name": "Black", "probability": 0.9945 } ],
      "angle": [ { "name": "front-right", "probability": 1.0 } ]
    }
  ]
}
```

The [API description](https://app.swaggerhub.com/apis-docs/CarNET.ai/MMG/2.1) lists every parameter and field. The [list of supported cars](https://carnet.ai/cars) shows which generations it knows.

## Keep your key secret

Anyone who has your key can spend its requests. Keep it on a server or on your own computer:

- Never put it into a web page. The [micro website](web/) shows how a small server adds the key to each request.
- An app you publish should send photos through your own server, not straight to the API with the key inside the app. The apps' API address setting can point at the micro website's server, which adds the key.

## CarNET Server

[CarNET Server](https://carnet.ai/on-premise) runs the same recognition on your own machine. Every sample has a setting for the API's address: point it at `http://YOUR-SERVER:50052/detect`. CarNET Server needs no key.

## Licence

MIT: copy the code into your own projects freely. See [LICENSE](LICENSE).

The example photos (in `web/public/examples`, `ios/CarRecognition/example.jpg` and `android/app/src/main/assets/example.jpg`) and the screenshots that show them are only for running and showing the samples. They are not covered by the MIT licence.
