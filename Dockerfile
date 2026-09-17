FROM python:3.14-alpine as build

WORKDIR /app

COPY ./requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.14-alpine as static-build

WORKDIR /app

COPY --from=build /install /usr/local

COPY ./task ./task

RUN mkdocs build -f ./task/mkdocs.yml

FROM nginx:alpine

WORKDIR /app

COPY --from=static-build /app/task/site /app/task/site
COPY ./nginx/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 8000

CMD ["nginx", "-g", "daemon off;"]