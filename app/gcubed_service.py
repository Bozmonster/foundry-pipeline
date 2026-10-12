"""Thin service layer around the G-Cubed Python package.

Loads (or solves once) the configured G-Cubed model, keeps the solved model and
baseline projections in memory, and runs baseline queries or custom shock
experiments on request. Everything returned is plain JSON-serialisable data.
"""

from __future__ import annotations

import logging
import os
import shutil
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml
from joblib import dump, load

logger = logging.getLogger("gcubed_service")

MODEL_ROOT = Path(os.environ.get("GCUBED_ROOT", "/srv/model"))
MODEL_VERSION = os.environ.get("GCUBED_MODEL_VERSION", "2R")
MODEL_BUILD = os.environ.get("GCUBED_MODEL_BUILD", "199")
MODEL_DIR = MODEL_ROOT / MODEL_VERSION / MODEL_BUILD
SOLVED_MODEL_FILE = Path(
    os.environ.get("GCUBED_SOLVED_MODEL", "/srv/cache/solved_model.joblib")
)

DEFAULT_VARIABLES = ["GDPR", "INFL", "INTN", "INTR", "EXCH", "TBAL"]
MAX_VARIABLES = 200


class RequestError(ValueError):
    """Raised for invalid client input (maps to HTTP 400)."""


@dataclass
class Shock:
    variable: str
    value: float
    start_year: int
    end_year: int | None = None

    @classmethod
    def parse(cls, raw: dict[str, Any]) -> "Shock":
        try:
            variable = str(raw["variable"]).strip()
            value = float(raw["value"])
            start_year = int(raw["start_year"])
            end_year = raw.get("end_year")
            end_year = int(end_year) if end_year is not None else None
        except (KeyError, TypeError, ValueError) as exc:
            raise RequestError(
                "Each shock needs 'variable' (e.g. 'INFX(USA)'), numeric 'value' "
                f"and integer 'start_year'; optional 'end_year'. Problem: {exc}"
            ) from exc
        if end_year is not None and end_year < start_year:
            raise RequestError(f"Shock {variable}: end_year is before start_year")
        return cls(variable, value, start_year, end_year)


class GCubedService:
    """Holds the solved model and answers requests. Thread-safe via a lock."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._configuration = None
        self._solved_model = None
        self._baseline = None
        self.load_seconds: float | None = None

    # ------------------------------------------------------------------ setup
    def ensure_loaded(self) -> None:
        if self._baseline is not None:
            return
        with self._lock:
            if self._baseline is not None:
                return
            started = time.perf_counter()
            from gcubed.model import Model
            from gcubed.model_configuration import ModelConfiguration
            from gcubed.linearisation.solved_model import SolvedModel
            from gcubed.projections.baseline_projections import BaselineProjections

            config_file = MODEL_DIR / "model_configuration.yaml"
            if not config_file.is_file():
                raise FileNotFoundError(f"Model configuration not found: {config_file}")
            configuration = ModelConfiguration(configuration_file=config_file)
            if str(configuration.python_directory) not in sys.path:
                sys.path.insert(0, str(configuration.python_directory))

            if SOLVED_MODEL_FILE.is_file():
                logger.info("Loading solved model from %s", SOLVED_MODEL_FILE)
                with SOLVED_MODEL_FILE.open("rb") as fh:
                    solved_model = load(fh)
            else:
                logger.info("Solving model %s/%s", MODEL_VERSION, MODEL_BUILD)
                solved_model = SolvedModel(model=Model(configuration=configuration))
                SOLVED_MODEL_FILE.parent.mkdir(parents=True, exist_ok=True)
                with SOLVED_MODEL_FILE.open("wb") as fh:
                    dump(solved_model, fh, compress=("zlib", 0))

            self._configuration = configuration
            self._solved_model = solved_model
            self._baseline = BaselineProjections(solved_model=solved_model)
            self.load_seconds = round(time.perf_counter() - started, 3)
            logger.info("Model ready in %ss", self.load_seconds)

    # --------------------------------------------------------------- queries
    def describe(self) -> dict[str, Any]:
        self.ensure_loaded()
        meta = self._baseline.charting_projections[
            ["prefix", "description", "units"]
        ].drop_duplicates("prefix")
        years = [int(y) for y in self._baseline.publishable_projections.columns]
        return {
            "model": {"version": MODEL_VERSION, "build": MODEL_BUILD},
            "years": {"first": years[0], "last": years[-1]},
            "regions": sorted(self._baseline.charting_projections["region"].dropna().unique().tolist()),
            "variable_prefixes": [
                {"prefix": r.prefix, "description": r.description, "units": r.units}
                for r in meta.itertuples()
            ],
            "example_request": example_request(),
        }

    def run(self, request: dict[str, Any]) -> dict[str, Any]:
        self.ensure_loaded()
        started = time.perf_counter()
        shocks = [Shock.parse(s) for s in request.get("shocks") or []]
        variables = request.get("variables") or DEFAULT_VARIABLES
        if not isinstance(variables, list) or len(variables) > MAX_VARIABLES:
            raise RequestError(f"'variables' must be a list of at most {MAX_VARIABLES} names")
        first_year = int(request.get("first_year", self._baseline.first_projection_year))
        last_year = int(request.get("last_year", first_year + 20))

        baseline_df = self._baseline.publishable_projections
        rows = self._select_rows(baseline_df.index, variables)
        cols = [c for c in baseline_df.columns if first_year <= int(c) <= last_year]
        if not cols:
            raise RequestError("No projection years in the requested first_year/last_year range")

        meta = self._baseline.charting_projections
        result: dict[str, Any] = {
            "model": {"version": MODEL_VERSION, "build": MODEL_BUILD},
            "years": [int(c) for c in cols],
            "variables": {
                name: {
                    "description": str(meta.at[name, "description"]),
                    "units": str(meta.at[name, "units"]),
                }
                for name in rows
            },
            "baseline": _frame(baseline_df, rows, cols),
        }

        projections = [self._baseline]
        if shocks:
            experiment = self._run_experiment(shocks, request.get("name") or "API experiment")
            projections.append(experiment)
            experiment_df = experiment.publishable_projections
            result["shocks"] = [s.__dict__ for s in shocks]
            result["experiment"] = _frame(experiment_df, rows, cols)
            result["deviation_from_baseline"] = _frame(
                experiment_df.loc[rows, cols] - baseline_df.loc[rows, cols], rows, cols
            )
        if request.get("report") == "html":
            result["html_reports"] = self._html_reports(
                projections, variables, int(cols[0]), int(cols[-1]),
                request.get("name") or "G-Cubed API run", shocks,
            )
        result["elapsed_seconds"] = round(time.perf_counter() - started, 3)
        return result

    def _html_reports(self, projections, variables, first_year, last_year, title, shocks) -> dict[str, str]:
        """Render G-Cubed's own interactive HTML chart reports for this run."""
        from gcubed.reporting import generate_all_simulation_results

        index = self._baseline.publishable_projections.index
        prefixes: list[str] = []
        for v in variables:
            prefix = str(v).split("(")[0].strip()
            # chart one-dimensional (per-region) variables; others stay in the JSON
            if prefix not in prefixes and any(
                i.split("(")[0] == prefix and "," not in i for i in index
            ):
                prefixes.append(prefix)
        if not prefixes:
            raise RequestError("None of the requested variables can be charted by region")

        chartpack = [{"chartpack": {"format": "gcubed-chartpack", "version": 1, "title": title,
                                    "defaults": {"start_year": first_year, "end_year": last_year}}}]
        chartpack += [{"chart": {"series": [{"variable_prefix": p, "selectors": {"regions": "all"}}]}}
                      for p in prefixes]
        shock_text = "".join(
            f"\n- `{s.variable}` {s.value:+g} from {s.start_year}"
            + (f" to {s.end_year}" if s.end_year else " (permanent)") for s in shocks
        ) or "\n- none (baseline only)"
        documentation = (
            f"Generated by the G-Cubed API on Microsoft Foundry (model {MODEL_VERSION}/{MODEL_BUILD}).\n\n"
            f"Shocks:{shock_text}\n"
        )
        workdir = Path(tempfile.mkdtemp(prefix="gcubed_report_"))
        try:
            (workdir / "chartpack.yaml").write_text(yaml.safe_dump(chartpack, sort_keys=False))
            (workdir / "documentation.md").write_text(documentation)
            with self._lock:
                generate_all_simulation_results(
                    chartpack_path=workdir / "chartpack.yaml",
                    documentation_path=workdir / "documentation.md",
                    template_path=self._configuration.templates_directory / "chart-template-2.0.html",
                    results_directory_path=workdir / "results",
                    all_projections=projections,
                    show_final_results=False,
                )
            return {
                f.name: f.read_text(encoding="utf-8")
                for f in sorted((workdir / "results").rglob("*.html"))
            }
        finally:
            shutil.rmtree(workdir, ignore_errors=True)

    # --------------------------------------------------------------- helpers
    @staticmethod
    def _select_rows(index, variables: list[str]) -> list[str]:
        """Accept full names like 'GDPR(USA)' or bare prefixes like 'GDPR'."""
        selected: list[str] = []
        for v in variables:
            v = str(v).strip()
            matches = [v] if v in index else [i for i in index if i.split("(")[0] == v]
            if not matches:
                raise RequestError(f"Unknown variable or prefix: {v}")
            selected.extend(m for m in matches if m not in selected)
        return selected

    def _run_experiment(self, shocks: list[Shock], name: str):
        from gcubed.runners.simulation_runner import SimulationRunner

        last_year = int(self._baseline.last_projection_year)
        event_year = min(s.start_year for s in shocks)
        years = list(range(event_year, last_year + 1))

        with self._lock:  # SimulationRunner reads files from the simulations folder
            workdir = Path(tempfile.mkdtemp(prefix="_api_", dir=self._configuration.simulations_directory))
            try:
                lines = ["name," + ",".join(str(y) for y in years)]
                for s in shocks:
                    end = s.end_year or last_year
                    vals = [s.value if s.start_year <= y <= end else 0 for y in years]
                    lines.append(f"{s.variable}," + ",".join(f"{v:g}" for v in vals))
                (workdir / "adjustments.csv").write_text("\n".join(lines) + "\n")
                design = {
                    "schema_version": 1,
                    "layers": [{
                        "name": name,
                        "data_file": "adjustments.csv",
                        "event_year": event_year,
                        "description": f"API experiment with {len(shocks)} shock(s)",
                    }],
                }
                (workdir / "design.yaml").write_text(yaml.safe_dump(design, sort_keys=False))
                runner = SimulationRunner(
                    baseline_projections=self._baseline,
                    experiment_design_file=f"{workdir.name}/design.yaml",
                )
                try:
                    runner.run()
                except Exception as exc:  # gcubed validates variable names etc.
                    raise RequestError(f"G-Cubed rejected the experiment: {exc}") from exc
                return list(runner.all_projections)[-1]
            finally:
                shutil.rmtree(workdir, ignore_errors=True)


def _frame(df, rows, cols) -> dict[str, list[float]]:
    sub = df.loc[rows, cols]
    return {name: [round(float(v), 6) for v in sub.loc[name].tolist()] for name in rows}


def example_request() -> dict[str, Any]:
    return {
        "action": "run",
        "variables": ["GDPR", "INFL", "INTN"],
        "first_year": 2023,
        "last_year": 2035,
        "shocks": [{"variable": "INFX(USA)", "value": 1, "start_year": 2024}],
    }


OPENAPI_SPEC: dict[str, Any] = {
    "openapi": "3.1.0",
    "info": {
        "title": "G-Cubed model API",
        "version": "1.0.0",
        "description": "Run the G-Cubed 2R macroeconomic model. POST /invocations with a JSON body.",
    },
    "paths": {
        "/invocations": {
            "post": {
                "summary": "Describe the model or run a baseline / shock experiment",
                "requestBody": {
                    "required": True,
                    "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Request"}, "example": example_request()}},
                },
                "responses": {"200": {"description": "Projections as JSON"}, "400": {"description": "Invalid input"}},
            }
        }
    },
    "components": {
        "schemas": {
            "Request": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["run", "describe", "health"], "default": "run"},
                    "report": {"type": "string", "enum": ["html"],
                               "description": "Also return G-Cubed's interactive HTML chart reports in html_reports"},
                    "variables": {"type": "array", "items": {"type": "string"},
                                  "description": "Full names like GDPR(USA) or prefixes like GDPR"},
                    "first_year": {"type": "integer"},
                    "last_year": {"type": "integer"},
                    "name": {"type": "string"},
                    "shocks": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "required": ["variable", "value", "start_year"],
                            "properties": {
                                "variable": {"type": "string", "example": "INFX(USA)"},
                                "value": {"type": "number"},
                                "start_year": {"type": "integer"},
                                "end_year": {"type": "integer"},
                            },
                        },
                    },
                },
            }
        }
    },
}
