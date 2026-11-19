# Brindle

- Brindle CI cancels the older run on the same branch, so a quick follow-up push can kill a deploy job.
- Brindle runs each job on a clean machine, so anything a job needs must be restored from the cache.
