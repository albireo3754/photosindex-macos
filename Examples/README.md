# Synthetic Examples

Files in this directory document public JSON contracts. They are synthetic and
must never be replaced with output from a real Photos library.

Included fixtures:

- `evidence-packet.example.json` — one synthetic evidence page with no real
  media or location.
- `model-decision.example.json` — a complete include/exclude partition with one
  selected asset.
- `model-decision-exclude-all.example.json` — a complete classification where
  nothing is selected for export or move.

Before using a decision template, replace every `run_example`,
`segment_example`, `ast_example_*`, and evidence reference with values from one
current PhotosIndex evidence packet.

For local experiments, keep derived files in the ignored `.photosindex/`
directory:

```bash
mkdir -p .photosindex
cp Examples/model-decision.example.json .photosindex/decision.json
photosindex decisions validate \
  --file .photosindex/decision.json \
  --format json
```

Validation against the unchanged example is expected to fail unless an in-app
index happens to use the same placeholders. That failure is intentional: move
and export plans must bind to the current app-owned index.

The Swift test suite decodes every JSON file here to keep the examples aligned
with the public Codable contracts.
