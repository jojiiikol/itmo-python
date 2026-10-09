---
name: habr-article-research
description: "Use when asked to find, read, or summarize Habr articles."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [habr, research, search, summarization, russian]
---

# Habr Article Research Skill

## When to Use

Load this skill when the user asks to find, read, summarize, or analyze Habr (Хабр)
publications — e.g. "найди новые статьи про Kafka", "популярные статьи про
PostgreSQL", "что нового на Хабре про asyncio".

Do NOT use it for general web research unrelated to Habr.

## Purpose

Find, read, summarize, and analyze Habr publications based on a user's
natural-language request.

Typical requests:

- `Найди новые статьи про Kafka на Хабре`
- `Найди популярные статьи про брокеры сообщений на Хабре`
- `Найди новые статьи про asyncio`
- `Найди популярные статьи про PostgreSQL за несколько страниц`

The skill must return a concise list in the form:

`Тема — про что — ссылка`

The agent must actually open the selected articles and base the summary on the
article content, not only on the search-result title or snippet.

---

## Supported request semantics

Interpret the user's wording as follows:

| User wording | `order` |
|---|---|
| новые, свежие, последние, recent | `date` |
| популярные, лучшие, с высоким рейтингом, top | `rating` |

If the user explicitly specifies another sorting mode, preserve it only if Habr
supports it. Otherwise use `date` or `rating` according to the table above.

If the user does not specify sorting, default to `date`.

Extract the search topic from the request. Do not add unnecessary words such as
`статьи`, `Хабр`, `найди`, `популярные`.

Example:

`Найди новые статьи про брокеры сообщений`

becomes:

- `q = брокеры сообщений`
- `order = date`

---

## Habr search endpoint (JSON API)

Use the Habr articles search API — NOT the HTML search page. The HTML
`/ru/search/` page renders results client-side (raw HTML contains only the
shell: `tm-articles-list` is absent, you get `«Нажмите на иконку поиска»`),
so HTML scraping cannot retrieve articles.

```text
https://habr.com/kek/v2/articles/?query=<URL_ENCODED_QUERY>&order=<ORDER>&fl=ru&hl=ru&page=<N>&perPage=<K>
```

| param | meaning |
|---|---|
| `query` | URL-encoded search topic |
| `order` | `date` (newest first), `rating` (highest-rated first), or `relevance` |
| `page` | page number, starts at 1 |
| `perPage` | items per page (20 is a good default) |
| `fl`, `hl` | language — keep `ru` |

Example:

```text
https://habr.com/kek/v2/articles/?query=%D0%B1%D1%80%D0%BE%D1%81%D0%BA%D0%B8&order=date&fl=ru&hl=ru&page=1&perPage=5
```

JSON response fields:

- `pagesCount` — total pages available
- `publicationIds` — ordered list of article IDs for this page
- `publicationRefs` — dict keyed by ID, each value is the article data

Per `publicationRefs[id]`:

| field | meaning |
|---|---|
| `id` | article id |
| `timePublished` | ISO datetime, e.g. `2026-10-08T10:22:39+00:00` |
| `titleHtml` | title with HTML markup (strip tags for plain text) |
| `publicationType` | `article` / `megaproject` / ... |
| `author` | `{alias, fullname, avatarUrl, ...}` |
| `statistics` | `{score, votesCount, favoritesCount, readingCount, commentsCount, reach, ...}` |
| `hubs` | list of `{alias, title}` |

The article URL is not a field — build it from the ID:

```text
https://habr.com/ru/articles/<id>/
```

Pagination: increment `page` until `pagesCount` is reached or you have
tenough relevant results. Keep `query`, `order`, `fl`, `hl` fixed between pages.

Do not manually concatenate unescaped user input into the URL.

---

## Search procedure

### 1. Parse the request

Determine:

1. topic/query;
2. sorting mode (`date` or `rating`);
3. requested number of results, if the user gave one;
4. otherwise use a reasonable default of 5 articles.

If the user says "несколько", use 5.

If the user asks for "10", return up to 10 relevant articles.

### 2. Search Habr

Call the JSON API endpoint for page 1.

If there are not enough relevant results, increment `page` and repeat until
you have enough, `pagesCount` is exhausted, or you have inspected at most
5 pages.

### 3. Extract candidate publications

For each ID in `publicationIds`, read `publicationRefs[id]` and collect:

- `titleHtml` (strip tags) → title;
- ID → URL `https://habr.com/ru/articles/<id>/`;
- `timePublished` → publication date;
- `statistics.score` / `statistics.favoritesCount` → rating;
- `author.alias` or `author.fullname` → author;
- `hubs` → useful for judging relevance.

Only keep entries whose `publicationType` is an article type (`article`,
`megaproject`). Skip anything that is not a publication.

### 4. Deduplicate

Do not return the same publication twice. Normalize URLs before comparison where
possible.

### 5. Read the articles

Open each selected article URL. Read enough of the article to understand:

- the main problem;
- the subject/topic;
- the main approach or idea;
- important technologies/concepts;
- the main conclusion;
- practical usefulness.

Do not summarize an article from its title alone.

If an article cannot be opened, do not invent its contents. Either skip it and
find another result, or explicitly mark it as unavailable if the user asked for
a specific article.

### 6. Analyze relevance

For each article, determine whether it is genuinely relevant to the requested
topic. Prefer articles where the requested topic is central rather than merely
mentioned once.

For example, for `брокеры сообщений` prefer articles about Kafka, RabbitMQ, NATS,
message queues, event streaming, delivery guarantees, producers/consumers, broker
architecture, and message delivery models — over an unrelated article that only
mentions Kafka in passing.

### 7. Summarize

Produce a short original summary for each selected article. The summary should
answer: "Что читатель узнает из этой статьи?"

Do not reproduce large portions of the article. Do not fabricate facts that are
absent from the article.

### 8. Synthesize across articles

Before producing the final answer, compare the selected articles. Identify
recurring themes, useful differences, or notable perspectives.

The analysis should be brief. It can be included after the list as
`Общий вывод: ...`

Do not turn the response into a long review unless the user explicitly asks for
detailed analysis.

---

## Output format

Default output:

```markdown
## Статьи на Хабре

1. **<Тема/название>** — <кратко: о чём статья>. <ссылка>
2. **<Тема/название>** — <кратко: о чём статья>. <ссылка>
3. **<Тема/название>** — <кратко: о чём статья>. <ссылка>

**Общий вывод:** <1–3 предложения о том, какие темы и подходы преобладают в найденных публикациях>.
```

The user specifically wants `Тема - про что - ссылка`. Therefore do not add
unnecessary metadata such as author, rating, date, or a long article description
unless it helps answer the request.

When useful, use the actual article title as `Тема`.

Links must point to the Habr article itself, not the search page.

---

## Sorting semantics

### `order=date`

Interpret as "newest first". When the user asks for new/recent articles,
prioritize the first relevant publications returned by Habr's date ordering.

### `order=rating`

Interpret as "highest-rated first". When the user asks for popular articles,
prioritize the first relevant publications returned by Habr's rating ordering.

Do not claim that "rating" means a specific absolute popularity metric beyond
Habr's own ordering.

---

## Pagination

Increment the `page` parameter:

```text
page 1:
https://habr.com/kek/v2/articles/?query=<query>&order=<order>&fl=ru&hl=ru&page=1&perPage=20

page N:
https://habr.com/kek/v2/articles/?query=<query>&order=<order>&fl=ru&hl=ru&page=N&perPage=20
```

Keep `query`, `order`, `fl`, `hl` and `perPage` identical on every page. Stop at
`pagesCount`.

Example for `брокеры`:

```text
https://habr.com/kek/v2/articles/?query=%D0%B1%D1%80%D0%BE%D0%BA%D0%B5%D1%80%D1%8B&order=date&fl=ru&hl=ru&page=1&perPage=20
```

---

## Failure handling

### Search page does not expose article results

If the API returns no `publicationRefs` or the request fails with HTTP 4xx/5xx:

1. retry once — Habr occasionally times out on TLS handshake;
2. if it still fails, report that Habr search could not be read instead of
   inventing results;
3. do NOT fall back to scraping `/ru/search/` HTML — it renders client-side
   and contains no publications.

Never report a search as successful when no articles were actually returned.

### Article is unavailable

Skip the article and continue searching unless the user explicitly requested
that article.

### Too few relevant results

Return the relevant results found and state briefly that fewer matching
publications were available. Do not fill the list with weakly related articles
just to reach the requested count.

### Habr blocks automated access

Do not attempt to bypass CAPTCHA, authentication, access controls, or anti-bot
protections. Report the access limitation and return only information that was
legitimately accessible.

---

## Important behavioral rules

1. Always search Habr for this skill; do not answer from model memory when the
   user asks for current/new/popular articles.
2. Always read selected articles before summarizing them.
3. Keep the original Habr article URL in the final result.
4. Use URL encoding for `query`.
5. Use the `/kek/v2/articles/` JSON API, not HTML scraping.
6. Use `date` for "new/recent/latest".
7. Use `rating` for "popular/best/top".
8. Follow pagination when necessary.
9. Deduplicate articles.
10. Do not invent article contents, titles, ratings, dates, or links.
11. Prefer relevance over filling the requested number.
12. Keep summaries concise unless the user asks for detailed analysis.
13. Respect Habr's access restrictions and do not bypass anti-bot mechanisms.

---

## Example

User:

> Найди новые статьи про брокеры сообщений на Хабре

Internal interpretation:

```text
query = "брокеры сообщений"
order = "date"
limit = 5
```

Search:

```text
https://habr.com/kek/v2/articles/?query=%D0%B1%D1%80%D0%BE%D0%BA%D0%B5%D1%80%D1%8B%20%D1%81%D0%BE%D0%BE%D0%B1%D1%89%D0%B5%D0%BD%D0%B8%D0%B9&order=date&fl=ru&hl=ru&page=1&perPage=5
```

Then read the most relevant articles and answer approximately:

```markdown
## Статьи на Хабре

1. **Kafka и гарантии доставки сообщений** — статья разбирает ...
   https://habr.com/ru/articles/...

2. **RabbitMQ под высокой нагрузкой** — автор показывает ...
   https://habr.com/ru/articles/...

3. **NATS для событийной архитектуры** — материал рассматривает ...
   https://habr.com/ru/articles/...

**Общий вывод:** в найденных публикациях чаще всего рассматриваются ...
```

The exact articles and summaries must come from the current Habr search and
article contents, not from this example.