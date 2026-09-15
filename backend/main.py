from fastapi import FastAPI

app = FastAPI(title="KisanRider API")

@app.get("/")
def read_root():
    return {"status": "Online", "message": "KisanRider FastAPI Server Running"}