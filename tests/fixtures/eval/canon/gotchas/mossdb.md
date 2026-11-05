# Mossdb

- Mossdb now() returns the transaction start time, not the moment of the call.
- Mossdb now() returns the transaction start time, not the moment of the call itself.
- A Mossdb migration that adds an index locks the table; build the index concurrently on large tables.
- Mossdb connection pools default to ten connections, which the Marrow API exhausts during the nightly import.
