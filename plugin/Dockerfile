FROM mirror.gcr.io/library/python:3.12-alpine
RUN pip install --no-cache-dir kanboard
COPY entrypoint.py /harness/entrypoint.py
ENTRYPOINT ["python", "/harness/entrypoint.py"]
