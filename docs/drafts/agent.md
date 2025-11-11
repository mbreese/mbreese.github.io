---
status: draft
date: 2025-11-10
icon: lucide/bot
title: Building an LLM interface in anger
description: Building an agentic LLM interface from scratch with Go
---

# Building an LLM interface in anger

## Background

I tend to come at technology from a sketical point of view. I'm also fairly convinced that magic isn't real. Together, this has kept me pretty hesistant to use LLMs for more than some trivial editing, idea brainstorming, or coding assistance. Tools like Claude and ChatGPT are great at those things, but I was recently drawn into using some custom tools for chatbots. At `$WORK`, I have access to an in-house instance of `gpt-oss-120b` (two actually). This means that I have pretty much unlimited access to this model as an API.

### First attempt

My first attempt used [Open WebUI](https://openwebui.com/) interface connected to `gpt-oss-120b` and a couple of custom written MCP servers. This was a great way to get something running quickly that was a good proof of concept. I could ask questions of the model and it would answer using the data tools I provided. This also got me to see the utility of adding LLMs to my daily toolkit.

This was a great proof of concept, but not a great production interface for my work. I need to let other people have access to my chatbot and I don't want to create/manage user accounts on Open WebUI. I'm also not sure how the MCP servers I wrote are wired up to the LLM (and I don't like magic or blackboxes).

### Take two

Next I tried to make a new Web interface using Python and the [Pocket Flow](https://the-pocket.github.io/PocketFlow/) framework. This is a pretty easy LLM framework to work your head around and it's very configurable. Once I got the initial workflow wired up, I used OpenAI Codex to help me vibe code a full web interface. This interface uses websockets to communicate between a FastAPI based web app and the frontend. The new chatbot supports MCP tool calling (as a client) and talks to our `gpt-oss-120b` model through API calls. All in all, it works pretty well, except for that it doesn't handle streaming responses well. 

![Chat LLM screenshot](chat2.png)

I actually really like the way this works, and I was pretty impressed with how well the interactions with the LLM work. Tools get called appropriately and the LLM can answer questions effectively. However, attempts to add streaming responses has shown that the initial codebase is actually quite fragile. When I start to add code for streaming responses from the LLM, tool calling is broken. Perhaps I should have started with Langchain to begin with. Either way, this fragility, coupled with my lack of understanding of the vibe-coded data flow and some necessary new features, has led me to think that I'll have to start with a new project from scratch. A fresh start where I can apply what I've already learned to a new chat interface where I know more about what features will be required.

I'm also going to write this new version in Go.

Why Go? Because it is much easier to deploy and I think a strongly typed compiled language can be a bit easier to understand. I also like Go.