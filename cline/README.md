# Cline Configuration

Configuration for Cline VS Code extension with local vLLM backend.

## What is Cline

Cline is an AI coding assistant extension for VS Code that can edit files, run commands, and help with development tasks.

## Installation

Install from VS Code Marketplace: search for "Cline" in the Extensions panel.

## vLLM Setup

1. Open Cline settings (gear icon in the Cline panel)
2. Set **API Provider** to "OpenAI Compatible"
3. Configure the following:
   - **Base URL**: `http://192.168.62.138:9000/v1`
   - **API Key**: `EMPTY` (or any string like `sk-dummy` - vLLM doesn't require auth by default)
   - **Model ID**: `mistralai/Devstral-Small-2-24B-Instruct-2512`

## Model Configuration

You may want to adjust these settings based on Devstral's specifications:

- **Context window size**: Check the model's max context length
- **Max output tokens**: Adjust based on your needs

## Notes

- The vLLM server must be running at the specified endpoint before using Cline
- No authentication is required for the local vLLM setup
