import os
from dotenv import load_dotenv
from fastapi import FastAPI
from google.adk.cli.fast_api import get_fast_api_app

load_dotenv()

# Mount the ADK-generated app (handles /run, /run_sse, agent routes)
adk_app = get_fast_api_app()

app = FastAPI(title="Rena Agent API")
app.mount("/", adk_app)
