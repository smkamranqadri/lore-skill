# Brindle cache

- Brindle caches the dependency folder by lockfile hash; editing the lockfile by hand leaves a stale cache.
- Brindle drops a cache that nobody has restored for a week, so a rare job always starts cold.
