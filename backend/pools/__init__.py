"""
KisanRider farmer pooling — Phase 1 (models + schemas only).

Importing ``pools.models`` (done from ``main.py`` right after
``import models``) registers the new ``pools``, ``pool_members``, and
``pool_stops`` tables on the shared ``Base.metadata`` so
``Base.metadata.create_all(...)`` in the FastAPI lifespan provisions
them on startup.

No router, CRUD functions, or endpoints live in this package yet — those
land in Phase 2/3.
"""