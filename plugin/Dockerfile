FROM mirror.gcr.io/library/python:3.12-alpine
RUN pip install --no-cache-dir kanboard
WORKDIR /harness
COPY entrypoint.py .
ENTRYPOINT ["python", "entrypoint.py"]
