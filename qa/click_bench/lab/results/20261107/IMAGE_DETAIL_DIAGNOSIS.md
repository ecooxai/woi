# Why native image detail matters for click coordinates

**Date:** 2026-11-07

**Evidence:** [image-detail-ablation.json](image-detail-ablation.json)

The initial screening used `detail: "high"` for every model. Five text models
passed all 12 cases; five others passed 8/12 and missed the same four 2560×1440
cases. Their 960×720 and 1280×720 cases succeeded. The large-image errors were
approximately a uniform scale: GPT-6-Luna returned about 0.822 times the native
coordinates, and GPT-5.6-Terra, GPT-Reserve and Codex Auto Review about 0.800 times.
The image hashes, native dimensions and DPR declarations matched across models.
The browser oracle passed with the correct native coordinates, so these errors
did not come from the local pixel-to-browser mapping.

OpenAI's [images and vision guide](https://developers.openai.com/api/docs/guides/images-vision)
distinguishes general high-detail understanding from tasks requiring precise
original-image coordinates. Its [computer-use integration guide](https://developers.openai.com/api/docs/guides/tools-computer-use-integration)
recommends original detail when supported. The live Codex model catalog advertised
`supports_image_detail_original: true` for all ten text candidates in this run.
The public model catalog can omit this capability; omission is treated as unknown.

## Controlled check

After the complete 192-trial baseline finished, the four failed large-image cases
were repeated for GPT-6-Luna and GPT-5.6-Terra using `detail: "original"`.
The PNG bytes, dimensions, screen/DPR metadata, instruction, system prompt,
reasoning effort (`low`), tool schema, and target geometry were held constant.
Each request was fresh. No coordinate rescaling, clamping, accessibility lookup,
or second-model correction was applied.

| Model | High detail | Original detail |
| --- | ---: | ---: |
| gpt-6-luna | 0/4 | 4/4 |
| gpt-5.6-terra | 0/4 | 4/4 |

The independent browser dispatched actual trusted click/move events. All eight
original-detail requests hit the intended button with the requested action;
pointer moves generated no clicks. For example, a native target centered near
(1499.2, 313.3) received (1232, 258) from Luna with high detail and (1500, 315)
with original detail.

This isolates the detail setting as the cause of the observed failures in these
eight paired cases. It does not establish universal accuracy for either model,
or turn this targeted diagnostic into an independent random test set. The main
native-detail screening and confirmation are reported separately.

The original baseline file remained byte-for-byte unchanged before and after the
diagnostic. SHA-256:

```
30fdd7cecae7eb3a38e5d2366d950f9833cf71afbb1d120f01947d5764605a35
```

## Delivered policy

`screenshot-only-v2` defaults to `WOI_LAB_IMAGE_DETAIL=auto`:

- Responses models with catalog-confirmed original support receive `original`.
- Realtime and models with unknown original support receive `high`.
- `--image-detail high` reproduces the initial image-detail configuration.
- An explicit unsupported `original` request fails visibly without fallback.

The source image bytes never change. Every result records its protocol, selected
detail and policy, image hash, dimensions and reasoning effort. High-detail
baseline results and native-detail results must remain labeled separately.
