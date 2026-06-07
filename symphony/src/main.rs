use std::path::PathBuf;

use clap::{Parser, Subcommand};
use symphony::{
    daemon, doctor, init_workflow, print_report, run_issue, run_queue, DaemonOptions,
    DoctorOptions, RunOptions, RunQueueOptions,
};

#[derive(Parser)]
#[command(
    name = "symphony",
    version,
    about = "Auditorium headless orchestration runner"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Create a starter WORKFLOW.md in the current directory.
    Init {
        /// Refuse to overwrite an existing file.
        #[arg(long, default_value_t = false)]
        check: bool,
        /// Path to write.
        #[arg(long, default_value = "WORKFLOW.md")]
        workflow: PathBuf,
    },
    /// Check local runtime, GitHub, Codex, and workflow health.
    Doctor {
        /// Emit machine-readable JSON.
        #[arg(long)]
        json: bool,
        /// Workflow file to validate.
        #[arg(long, default_value = "WORKFLOW.md")]
        workflow: PathBuf,
    },
    /// Run one GitHub issue through a deterministic workspace.
    Run {
        /// GitHub repository in OWNER/NAME form.
        #[arg(long)]
        repo: String,
        /// GitHub issue number.
        #[arg(long)]
        issue: u64,
        /// Workflow file to read.
        #[arg(long, default_value = "WORKFLOW.md")]
        workflow: PathBuf,
        /// Workspace root. Overrides WORKFLOW.md.
        #[arg(long)]
        workspace_root: Option<PathBuf>,
        /// Emit NDJSON events.
        #[arg(long)]
        json: bool,
        /// Use an offline mock issue and skip network/Codex/git push.
        #[arg(long)]
        mock: bool,
        /// Prepare/report without launching Codex or creating a PR.
        #[arg(long)]
        dry_run: bool,
        /// Do not open a pull request even if changes are committed.
        #[arg(long)]
        no_pr: bool,
    },
    /// Run a queue of GitHub issues with bounded concurrent agents.
    RunQueue {
        /// GitHub repository in OWNER/NAME form.
        #[arg(long)]
        repo: String,
        /// Comma-separated GitHub issue numbers.
        #[arg(long, value_delimiter = ',')]
        issues: Vec<u64>,
        /// Workflow file to read.
        #[arg(long, default_value = "WORKFLOW.md")]
        workflow: PathBuf,
        /// Workspace root. Overrides WORKFLOW.md.
        #[arg(long)]
        workspace_root: Option<PathBuf>,
        /// Emit NDJSON events.
        #[arg(long)]
        json: bool,
        /// Use offline mock issues and skip network/Codex/git push.
        #[arg(long)]
        mock: bool,
        /// Prepare/report without launching Codex or creating a PR.
        #[arg(long)]
        dry_run: bool,
        /// Do not open pull requests even if changes are committed.
        #[arg(long)]
        no_pr: bool,
    },
    /// Run one daemon scheduling pass for a project id.
    Daemon {
        /// Project identifier from the macOS app.
        #[arg(long)]
        project: String,
        /// Workflow file to read.
        #[arg(long, default_value = "WORKFLOW.md")]
        workflow: PathBuf,
        /// Emit NDJSON events.
        #[arg(long)]
        json: bool,
        /// Keep running and reload WORKFLOW.md between scheduling ticks.
        #[arg(long)]
        watch: bool,
        /// Stop after this many ticks. Mainly useful for deterministic tests and smoke runs.
        #[arg(long)]
        max_ticks: Option<usize>,
        /// Override the workflow polling interval while watching.
        #[arg(long)]
        poll_interval_ms: Option<u64>,
    },
    /// Print a saved run report.
    Report {
        /// Report path or run id under the workspace reports directory.
        #[arg(long)]
        run: String,
        /// Workspace root used to resolve run ids.
        #[arg(long)]
        workspace_root: Option<PathBuf>,
    },
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();

    let cli = Cli::parse();
    let result = match cli.command {
        Commands::Init { check, workflow } => init_workflow(&workflow, check).await,
        Commands::Doctor { json, workflow } => doctor(DoctorOptions { json, workflow }).await,
        Commands::Run {
            repo,
            issue,
            workflow,
            workspace_root,
            json,
            mock,
            dry_run,
            no_pr,
        } => {
            run_issue(RunOptions {
                repo,
                issue,
                workflow,
                workspace_root,
                json,
                mock,
                dry_run,
                no_pr,
            })
            .await
        }
        Commands::RunQueue {
            repo,
            issues,
            workflow,
            workspace_root,
            json,
            mock,
            dry_run,
            no_pr,
        } => {
            run_queue(RunQueueOptions {
                repo,
                issues,
                workflow,
                workspace_root,
                json,
                mock,
                dry_run,
                no_pr,
            })
            .await
        }
        Commands::Daemon {
            project,
            workflow,
            json,
            watch,
            max_ticks,
            poll_interval_ms,
        } => {
            daemon(DaemonOptions {
                project,
                workflow,
                json,
                watch,
                max_ticks,
                poll_interval_ms,
            })
            .await
        }
        Commands::Report {
            run,
            workspace_root,
        } => print_report(run, workspace_root).await,
    };

    if let Err(error) = result {
        eprintln!("{}: {}", error.code(), error);
        std::process::exit(error.exit_code());
    }
}
