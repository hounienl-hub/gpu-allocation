#!/bin/bash
set -e

echo "Initializing Go module..."
go mod download
go mod tidy

echo "Go module initialized successfully"
echo "go.sum file created"
