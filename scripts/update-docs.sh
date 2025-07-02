#!/bin/bash

# Get extension name from Makefile
EXTENSION=$(make -s print-EXTENSION)

# Install mdextract globally
npm install -g mdextract

# Replace <docs> with include: <extension>.sql in README.md
sed -i "s/<docs>/include: ${EXTENSION}.sql/g" README.md

# Run mdextract --update README.md
mdextract --update README.md

# Replace the include comments back to <docs>
sed -i "s/include: ${EXTENSION}\.sql/<docs>/g" README.md

echo "Documentation update complete!"