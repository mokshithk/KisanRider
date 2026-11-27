from datetime import datetime, timezone
from types import SimpleNamespace

import main
import models
import pools.models


class _FakeQuery:
    def __init__(self, rows):
        self._rows = rows
        self.joins = []
        self.filters = []

    def join(self, *args):
        self.joins.append(args)
        return self

    def filter(self, *args):
        self.filters.extend(args)
        return self

    def all(self):
        return self._rows


class _FakeSession:
    def __init__(self, reqs, pool_rows, trip_pairs):
        self._by_entities = {
            (models.ProduceRequest,): reqs,
            (pools.models.Pool,): pool_rows,
            (models.Trip, models.ProduceRequest): trip_pairs,
        }
        self.queried = []
        self.committed = 0

    def query(self, *entities):
        self.queried.append(entities)
        return _FakeQuery(self._by_entities[entities])

    def commit(self):
        self.committed += 1


def test_expiry_worker_imports_session_local_and_pool_model():
    assert hasattr(main, "SessionLocal")
    assert main.SessionLocal is not None
    assert hasattr(pools.models, "Pool")


def test_run_expiry_check_once_updates_statuses_and_commits():
    req = SimpleNamespace(status="PENDING")
    pool_row = SimpleNamespace(status="OPEN")
    trip = SimpleNamespace(status="ACCEPTED")
    trip_req = SimpleNamespace(status="ACCEPTED")

    db = _FakeSession([req], [pool_row], [(trip, trip_req)])
    counts = main.run_expiry_check_once(db, now_utc=datetime(2026, 11, 27, tzinfo=timezone.utc))

    assert counts == (1, 1, 1)
    assert req.status == "EXPIRED"
    assert pool_row.status == "EXPIRED"
    assert trip.status == "MISSED"
    assert trip_req.status == "EXPIRED"
    assert db.committed == 1
    assert db.queried == [
        (models.ProduceRequest,),
        (pools.models.Pool,),
        (models.Trip, models.ProduceRequest),
    ]


def test_run_expiry_check_once_skips_commit_when_nothing_expired():
    db = _FakeSession([], [], [])
    counts = main.run_expiry_check_once(db)

    assert counts == (0, 0, 0)
    assert db.committed == 0
