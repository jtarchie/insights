# frozen_string_literal: true

require 'sqlite3'

# SQLite database interaction
class Database
  def initialize(db_path)
    @db = SQLite3::Database.new(db_path)
    @db.results_as_hash = true
    setup_schema
  end

  def close
    @db&.close
  end

  def setup_schema
    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS repositories (
        id INTEGER PRIMARY KEY,
        owner TEXT NOT NULL,
        name TEXT NOT NULL,
        UNIQUE(owner, name)
      );
    SQL

    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS pull_requests (
        id INTEGER PRIMARY KEY,
        repository_id INTEGER NOT NULL,
        pr_number INTEGER NOT NULL,
        title TEXT NOT NULL,
        author TEXT NOT NULL,
        merged_at TEXT NOT NULL,
        FOREIGN KEY(repository_id) REFERENCES repositories(id),
        UNIQUE(repository_id, pr_number)
      );
    SQL

    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS mainline_commits (
        id INTEGER PRIMARY KEY,
        repository_id INTEGER NOT NULL,
        sha TEXT NOT NULL,
        author TEXT,
        committed_at TEXT NOT NULL,
        pr_number INTEGER,
        FOREIGN KEY(repository_id) REFERENCES repositories(id),
        FOREIGN KEY(pr_number, repository_id) REFERENCES pull_requests(pr_number, repository_id),
        UNIQUE(repository_id, sha)
      );
    SQL
  end

  def get_repository_id(owner, name)
    @db.execute(
      'INSERT OR IGNORE INTO repositories (owner, name) VALUES (?, ?)',
      [owner, name]
    )

    result = @db.get_first_value(
      'SELECT id FROM repositories WHERE owner = ? AND name = ?',
      [owner, name]
    )
    result.to_i
  end

  def insert_pull_requests(repository_id, pull_requests)
    count = 0
    @db.transaction do
      pull_requests.each do |pr|
        next unless pr.author # Skip PRs without author info

        @db.execute(
          'INSERT OR REPLACE INTO pull_requests (repository_id, pr_number, title, author, merged_at)
           VALUES (?, ?, ?, ?, ?)',
          [repository_id, pr.number, pr.title, pr.author.login, pr.merged_at]
        )
        count += 1
      end
    end
    count
  end

  def insert_mainline_commits(repository_id, commits)
    count = 0
    @db.transaction do
      commits.each do |commit|
        next unless commit.author&.user # Skip commits without author info

        pr_number = nil
        if commit.associated_pull_requests.nodes.any?
          pr = commit.associated_pull_requests.nodes.first
          pr_number = pr.number

          # Insert the associated PR if it doesn't exist
          @db.execute(
            'INSERT OR IGNORE INTO pull_requests (repository_id, pr_number, title, author, merged_at)
             VALUES (?, ?, ?, ?, ?)',
            [repository_id, pr.number, pr.title, pr.author&.login || 'unknown', pr.merged_at || 'unknown']
          )
        end

        @db.execute(
          'INSERT OR REPLACE INTO mainline_commits (repository_id, sha, author, committed_at, pr_number)
           VALUES (?, ?, ?, ?, ?)',
          [repository_id, commit.oid, commit.author.user.login, commit.committed_date, pr_number]
        )
        count += 1
      end
    end
    count
  end

  def get_oldest_pr_date(repository_id)
    @db.get_first_value(
      'SELECT MIN(merged_at) FROM pull_requests WHERE repository_id = ?',
      [repository_id]
    )
  end

  def get_contributors(owner, name)
    @db.execute(<<-SQL, [owner, name]).map { |row| [row['author'], row['pr_count']] }
      SELECT
        pr.author,
        COUNT(*) as pr_count
      FROM
        pull_requests pr
      JOIN
        repositories r ON pr.repository_id = r.id
      WHERE
        r.owner = ? AND
        r.name = ?
      GROUP BY
        pr.author
      ORDER BY
        pr_count DESC;
    SQL
  end

  def get_yolo_coders(owner, name, days_range)
    since_date = (Date.today - days_range).strftime('%Y-%m-%d')

    @db.execute(<<-SQL, [owner, name, since_date]).map { |row|
 [row['author'], row['commit_count'], row['commit_shas']] }
      SELECT
        mc.author,
        COUNT(*) AS commit_count,
        GROUP_CONCAT(mc.sha, ',') AS commit_shas
      FROM
        mainline_commits mc
      JOIN
        repositories r ON mc.repository_id = r.id
      WHERE
        r.owner = ? AND
        r.name = ? AND
        date(mc.committed_at) >= ? AND
        mc.pr_number IS NULL  -- Only direct commits (not associated with a PR)
      GROUP BY
        mc.author
      ORDER BY
        commit_count DESC;
    SQL
  end
end
