"""Build-time step: solve the model once and bake the solved model into the image.

Fails the Docker build (and so the pipeline) if the model cannot be solved or a
smoke experiment does not run.
"""

import json

from gcubed_service import GCubedService, example_request

service = GCubedService()
service.ensure_loaded()
result = service.run(example_request())
print(json.dumps({
    "model": result["model"],
    "load_seconds": service.load_seconds,
    "sample_deviation_INFL(USA)": result["deviation_from_baseline"]["INFL(USA)"][:5],
}, indent=2))
