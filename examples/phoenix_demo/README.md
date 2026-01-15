# Durable Phoenix Demo

A sample Phoenix LiveView application demonstrating the [Durable](https://github.com/wavezync/durable) workflow engine with human-in-the-loop approval capabilities.

## Features

- **Document Processing Workflow**: A multi-step workflow that validates, parses, and transforms documents
- **Human-in-the-Loop**: Workflow pauses and waits for manager approval before proceeding
- **Real-time Updates**: LiveView pages update in real-time as workflows progress
- **Dashboard**: Monitor all workflow executions with status tracking
- **Approval Queue**: Review and approve/reject pending workflow approvals

## Getting Started

### Prerequisites

- Elixir 1.15+
- PostgreSQL 13+

### Setup

1. **Start the database** (using Docker):
   ```bash
   cd examples/phoenix_demo
   docker-compose up -d
   ```

   This starts PostgreSQL on port 53412.

2. **Install dependencies**:
   ```bash
   mix deps.get
   ```

3. **Create and migrate the database**:
   ```bash
   mix ecto.create
   mix ecto.migrate
   ```

4. **Start the server**:
   ```bash
   mix phx.server
   ```

5. **Open in browser**:

   Navigate to [http://localhost:4000](http://localhost:4000)

### Stopping the Database

```bash
docker-compose down
```

To also remove the data volume:
```bash
docker-compose down -v
```

## Usage

### Creating a Workflow

1. Click **"New Workflow"** in the navigation
2. Enter a filename (e.g., `report.pdf`, `data.csv`)
3. Click **"Start Workflow"**

### Workflow Steps

The document processing workflow goes through these steps:

1. **Validate Document** - Checks the file extension is valid
2. **Parse Content** - Extracts simulated content from the document
3. **Request Approval** - **Pauses** and waits for human approval
4. **Transform Data** - Processes the approved data
5. **Generate Report** - Creates the final report

### Approving Workflows

1. Navigate to **"Approvals"** in the navigation
2. You'll see pending approval requests
3. Click **"Review"** to see document details
4. Click **"Approve"** or **"Reject"**

When approved, the workflow resumes and completes. When rejected, it handles the rejection gracefully.

## Architecture

### Workflow Definition

```elixir
defmodule PhoenixDemo.Workflows.DocumentWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Context
  use Durable.Wait

  workflow "process_document", timeout: hours(24) do
    step :validate_document do
      # Validate document format
    end

    step :parse_content do
      # Extract content from document
    end

    step :request_approval do
      # Wait for human approval
      wait_for_approval("document_approval",
        prompt: "Please review the extracted document data"
      )
    end

    decision :check_approval do
      # Route based on approval response
    end

    step :transform_data do
      # Transform approved data
    end

    step :generate_report do
      # Generate final report
    end

    step :handle_rejection do
      # Handle rejection case
    end
  end
end
```

### Key Components

- **WorkflowLive**: Dashboard showing all workflow executions
- **DocumentLive**: Form to create new document workflows
- **ApprovalLive**: Queue for pending human approvals
- **WorkflowDetailLive**: Detailed view of a single workflow

### Database Tables

Durable creates these tables in the `durable` schema:

- `durable.workflow_executions` - Workflow instances
- `durable.step_executions` - Step execution history
- `durable.pending_inputs` - Human input requests

## Development

### Compiling

```bash
mix compile
```

### Running Tests

```bash
mix test
```

### Code Style

```bash
mix format
```

## Learn More

- [Durable Documentation](https://hexdocs.pm/durable)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view)
- [Ecto](https://hexdocs.pm/ecto)
