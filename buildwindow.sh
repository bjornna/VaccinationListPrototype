#!/bin/bash +x

cd build

dotnet-script build.csx -- "$@"

cd ..