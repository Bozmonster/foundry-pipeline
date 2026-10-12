"""G-Cubed API: a Microsoft Foundry hosted agent using the Invocations protocol.

Runs inside the container on port 8088. Foundry routes
POST {project}/agents/{agent}/endpoint/protocols/invocations to POST /invocations here.

Request body (JSON):
  {"action": "describe"}                      -> model metadata and variable list
  {"action": "health"}                        -> liveness and load time
  {"action": "run", "variables": [...], "first_year": 2023, "last_year": 2035,
   "shocks": [{"variable": "INFX(USA)", "value": 1, "start_year": 2024}]}
                                              -> baseline, experiment and deviations
"""

from __future__ import annotations

import asyncio
import logging
import os

from azure.ai.agentserver.invocations import InvocationAgentServerHost
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from gcubed_service import OPENAPI_SPEC, GCubedService, RequestError

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logging.getLogger("gcubed").setLevel(os.environ.get("GCUBED_LOG_LEVEL", "WARNING"))
logger = logging.getLogger("gcubed_api")

service = GCubedService()
app = InvocationAgentServerHost(openapi_spec=OPENAPI_SPEC)


@app.invoke_handler
async def handle(request: Request) -> Response:
    try:
        body = await request.json() if (await request.body()) else {}
    except ValueError:
        return JSONResponse({"error": "Body must be JSON"}, status_code=400)
    if not isinstance(body, dict):
        return JSONResponse({"error": "Body must be a JSON object"}, status_code=400)

    action = body.get("action", "run")
    try:
        if action == "health":
            await asyncio.to_thread(service.ensure_loaded)
            return JSONResponse({"status": "ok", "model_load_seconds": service.load_seconds})
        if action == "describe":
            return JSONResponse(await asyncio.to_thread(service.describe))
        if action == "run":
            return JSONResponse(await asyncio.to_thread(service.run, body))
        return JSONResponse({"error": f"Unknown action '{action}'"}, status_code=400)
    except RequestError as exc:
        return JSONResponse({"error": str(exc)}, status_code=400)
    except Exception as exc:  # pragma: no cover - surfaced to caller for debugging
        logger.exception("Invocation failed")
        return JSONResponse({"error": f"{type(exc).__name__}: {exc}"}, status_code=500)


if __name__ == "__main__":
    service.ensure_loaded()  # warm the model before accepting traffic
    app.run()
