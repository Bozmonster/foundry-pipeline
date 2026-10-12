# G-Cubed model API container for Microsoft Foundry hosted agents.
# Build context: repository root, after scripts/fetch-sources.sh has populated
#   model/   - checkout of the G-Cubed model repo (Bozmonster/gcubed.com-model-2R)
#   vendor/  - the gcubed Python wheel from McKibbin-Software-Group/gcubed-public-prerequisites
# Foundry requires linux/amd64 images.

# The gcubed wheel is byte-compiled for exactly CPython 3.14.5
FROM python:3.14.5-slim-bookworm

ARG GCUBED_WHEEL=gcubed-5.0.1.4-py3-none-any.whl
ARG GCUBED_MODEL_VERSION=2R
ARG GCUBED_MODEL_BUILD=199

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    GCUBED_ROOT=/srv/model \
    GCUBED_MODEL_VERSION=${GCUBED_MODEL_VERSION} \
    GCUBED_MODEL_BUILD=${GCUBED_MODEL_BUILD} \
    GCUBED_SOLVED_MODEL=/srv/cache/solved_model.joblib \
    PORT=8088

WORKDIR /srv/app

COPY vendor/${GCUBED_WHEEL} /tmp/
COPY app/requirements.txt /tmp/requirements.txt
RUN pip install /tmp/${GCUBED_WHEEL} -r /tmp/requirements.txt && rm /tmp/*.whl

COPY model/ /srv/model/
COPY app/ /srv/app/

# Solve the model at build time (also acts as a build-time smoke test)
RUN python prepare.py && chmod -R a+rwX /srv

EXPOSE 8088
CMD ["python", "main.py"]
