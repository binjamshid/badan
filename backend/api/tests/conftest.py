"""Put `backend/api/` on the import path.

The deployed layout is flat — `infra/badan-api.service` runs `uvicorn main:app`
with `WorkingDirectory=/srv/badan/code`, so `main.py` and `appattest.py` sit next
to each other and import each other by bare module name. The tests import them
the same way rather than as a package, so that an import that works here is an
import that works on the VPS.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
