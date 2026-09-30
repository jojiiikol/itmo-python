# Сравнение подходов к публикации страниц

Итоги сравнения двух подходов в публикации статичных страниц на ресурсе github

## peaceiris/actions-gh-pages

Кастомное [решение](https://github.com/peaceiris/actions-gh-pages) от автора [peaceiris](https://github.com/peaceiris)

### Подход

Коммит статических файлов в специальную ветку, например `gh-pages`  
GitHub в свою очередь публикует результаты в GitHub Pages

```bash
- name: Deploy to gh-pages
  uses: peaceiris/actions-gh-pages@v4
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    publish_dir: ./site
```

> #### Важно!
> GitHub должен быть настроен: Settings → Pages источник публикации установлен как "Deploy from a branch" и выбрана ветка gh-pages

## upload-pages-artifact + deploy-pages

Родной способ развёртывания, который GitHub продвигает как современный стандарт.  
Он основан на передаче артефактов и не требует создания дополнительных веток или коммитов в вашем репозитории.

### Подход

Создание артефакта и передача его в GitHub: Действие upload-pages-artifact упаковывает папку с сайтом в специальный артефакт.   
Затем deploy-pages разворачивает его на серверах Pages с использованием OIDC-токена (id-token: write) для аутентификации.  
*Никаких коммитов в ваш репозиторий не происходит.*

```bash
- name: Upload artifact
  uses: actions/upload-pages-artifact@v3
  with:
    path: site

- name: Deploy to GitHub Pages
  uses: actions/deploy-pages@v4
```

> #### Важно!
> GitHub должен быть настроен: Требует, чтобы в Settings → Pages источник был установлен как "GitHub Actions"

*Этот метод предъявляет строгие требования к артефакту: он должен быть назван github-pages, быть одним gzip-архивом, содержащим один tar-файл, размером до 1 ГБ (официальный лимит)*

## Сравнение

| Критерий | `peaceiris/actions-gh-pages` | `upload-pages-artifact` + `deploy-pages` |
| --- | --- | --- |
| Куда попадает результат сборки | В ветку `gh-pages` | Во временный Pages artifact |
| Требуется служебная ветка | Да | Нет |
| Способ настройки Pages | Ветка `gh-pages` | Источник `GitHub Actions` |
| Официальный механизм GitHub Pages | Нет, сторонний action | Да |

## Вывод

Оба подхода автоматизируют публикацию после push в `main`. `peaceiris/actions-gh-pages` делает публикацию через обычный push в ветку `gh-pages`, а официальная связка передаёт результат сборки в Pages без создания дополнительной ветки. В этом проекте используется официальный вариант, потому что он поддерживается GitHub и отделяет исходный код от опубликованного артефакта.
