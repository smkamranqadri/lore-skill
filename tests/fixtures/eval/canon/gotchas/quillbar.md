# Quillbar

- Quillbar embeds environment variables at build time, so changing one needs a rebuild, not a restart.
- Quillbar's watch mode silently stops when the config file is renamed; restart it after renaming the config.
- Quillbar caches transforms under .quill-cache; clear it after upgrading a plugin or stale output appears.
