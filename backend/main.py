from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy.orm import Session
from sqlalchemy import text
import models
from database import engine, get_db

# Create database tables in Supabase if they do not exist
models.Base.metadata.create_all(bind=engine)

app = FastAPI(title="KisanRider API")

@app.get("/")
def read_root():
    return {"status": "Online", "message": "KisanRider FastAPI Server Running"}

@app.get("/db-check")
def db_check(db: Session = Depends(get_db)):
    try:
        result = db.execute(text("SELECT PostGIS_Version();")).fetchone()
        return {"database": "Connected", "postgis_version": result[0]}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database connection failed: {str(e)}")