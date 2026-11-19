# Authelia — 2FA для pi.mishgun.com

Второй фактор (TOTP) на периметре Traefik. Схема:

```
браузер -> Traefik (pi.mishgun.com)
            |- forwardAuth -> authelia:9091  (пароль + TOTP)
            |- pi-web 192.168.2.200:30141     (свой пароль PI_WEB_PASSWORD)
```

Портал — `login.mishgun.com`, а НЕ `auth.mishgun.com`: `auth.mishgun.com`
уже занят acme-dns (`files/acme-dns/config.cfg`: `domain`/`nsname`) и
делегирован у регистратора (NS `auth.mishgun.com`) — это штатная схема
ACME DNS-01.

Пароль pi-web остаётся: он защищает прямой доступ к `192.168.2.200:30141`
в обход Traefik. Итого: Authelia (пароль + TOTP) + пароль приложения.
## Файлы

| Файл на хосте traefik_lxc | Источник |
| --- | --- |
| `/home/docker/authelia/configuration.yml` | `roles/traefik/config/files/authelia/configuration.yml` |
| `/home/docker/authelia/users_database.yml` | шаблон `templates/authelia/users_database.yml.j2` + vault |
| `/home/docker/authelia/secrets/*` | генерируются ролью, `0600` (в git не попадают) |
| `/home/docker/authelia/db.sqlite3` | runtime (устройства TOTP, сессии, попытки входа) |

## Первый запуск

1. Сгенерировать argon2id-хеш пароля (на control-node):

   ```bash
   docker run --rm authelia/authelia:4.39 \
     authelia crypto hash generate argon2 --password 'ПАРОЛЬ'
   ```

2. Добавить в `ansible/group_vars/all/vault.yml`:

   ```yaml
   vault_authelia_pi_password_hash: "$argon2id$v=19$m=65536,t=3,p=4$..."
   ```

   и перешифровать: `sops -e ... > ansible/vault.sops.yml` (или
   `./useful_scripts/control/init-ansible-vault.sh`).

3. Задеплоить роль `traefik/config`.

4. Открыть https://login.mishgun.com, войти как `pi` + пароль.

5. Портал сам предложит зарегистрировать второй фактор — TOTP
   (Google Authenticator/Aegis/1Password). Сохранить резервные коды,
   если предлагаются.

6. Проверить https://pi.mishgun.com: должен быть редирект на портал,
   затем после TOTP — приложение.

## Смена пароля

Хеш в vault + передеплой роли (runtime users_database перезаписывается).
Смена самого второго фактора — в портале (Manage devices).

## Если потерян TOTP

Сброс — через CLI в контейнере (пароль пользователя при этом сохраняется):

```bash
docker exec -it authelia authelia storage user totp delete pi
```

## Важно

`vault_authelia_pi_password_hash` обязателен: роль проверяет его в самом
начале (`assert`) и падает до изменения конфигов, чтобы не оставить
`pi.mishgun.com` без работающего forward-auth.

## Бэкап

`/home/docker/authelia/db.sqlite3` содержит seed'ы TOTP и сессии, но в
ролевые бэкапы Traefik (acme/crowdsec/acme-dns) не входит. При потере
хоста TOTP перерегистрируется в портале за минуту; пароль восстановится
из vault. Отдельный бэкап БД не обязателен, но если нужен — копировать
`db.sqlite3` + `secrets/storage_encryption_key` только вместе (без
ключа БД не расшифруется).
