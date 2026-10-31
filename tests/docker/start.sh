#!/bin/sh
# Vendor bootstrap fixture: networking is confined to this disposable container.
/usr/local/bin/fixture-network
tail -f /dev/null
