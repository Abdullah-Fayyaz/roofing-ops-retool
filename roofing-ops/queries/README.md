# Retool queries

Do not use `{{ current_user.groups.map(...) }}` or any other JS built from current_user for access
decisions. Retool's query-spoofing protection checks plain current_user references; derived JavaScript is
evaluated in the browser. We pass only `{{ current_user.email }}` and resolve role, region and crew in the
database (core.app_users).

The Retool resource connects as `retool_app`, which can only EXECUTE the four api.* functions. Even a
hand-edited query from the app cannot read core.jobs or core.claims directly.
