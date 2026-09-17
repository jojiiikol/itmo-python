FROM python:3.14-alpine as build

WORKDIR /app

COPY ./requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.14-alpine

WORKDIR /app

COPY --from=build /install /usr/local

COPY ./task ./task

EXPOSE "8000"
CMD ["mkdocs", "serve", "-f", "task/mkdocs.yml", "-a", "0.0.0.0:8000"]