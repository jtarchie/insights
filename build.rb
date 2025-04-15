# frozen_string_literal: true

require 'graphql/client'
require 'graphql/client/http'
require 'sqlite3'
require 'date'
require 'optparse'
require 'erb'

# GitHub GraphQL API Client
HTTP = GraphQL::Client::HTTP.new('https://api.github.com/graphql') do
  def headers(_context)
    { 'Authorization' => "Bearer #{ENV['GITHUB_TOKEN']}" }
  end
end
Schema = GraphQL::Client.load_schema(HTTP)
Client = GraphQL::Client.new(schema: Schema, execute: HTTP)

PullRequestsQuery = Client.parse <<-'GRAPHQL'
  query($owner: String!, $name: String!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequests(first: 100, states: MERGED, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
        pageInfo {
          endCursor
          hasNextPage
        }
        edges {
          node {
            number
            title
            author {
              login
            }
            mergedAt
          }
        }
      }
    }
  }
GRAPHQL

# Parse Command-Line Arguments
options = {}
OptionParser.new do |opts|
  opts.banner = 'Usage: ruby lottery_factor_tool.rb [options]'

  opts.on('-r', '--repo REPO', "The GitHub repository in 'username/repo' format") do |repo|
    options[:repo] = repo
  end

  opts.on('-d', '--database FILENAME', 'The SQLite database filename') do |filename|
    options[:database] = filename
  end

  opts.on('-t', '--time-range DAYS', Integer, 'The time range in days') do |days|
    options[:time_range] = days
  end

  opts.on('-o', '--output FILENAME', 'The output HTML filename') do |output|
    options[:output] = output
  end
end.parse!

# Validate Required Arguments
unless options[:repo] && options[:database] && options[:time_range]
  puts 'Error: Missing required arguments.'
  puts 'Usage: ruby lottery_factor_tool.rb -r username/repo -d database.db -t 30 -o output.html'
  exit 1
end

# Extract Repository Details
repo_owner, repo_name = options[:repo].split('/')
if !repo_owner || !repo_name
  puts "Error: Invalid repository format. Use 'username/repo'."
  exit 1
end

# Default output file
options[:output] ||= "#{repo_owner}-#{repo_name}-lottery.html"

# SQLite Setup
db = SQLite3::Database.new options[:database]

# Create Tables
db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS repositories (
    id INTEGER PRIMARY KEY,
    owner TEXT NOT NULL,
    name TEXT NOT NULL,
    UNIQUE(owner, name)
  );
SQL

db.execute <<-SQL
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

db.execute <<-SQL
  CREATE VIEW IF NOT EXISTS top_contributors AS
  SELECT
    r.owner || '/' || r.name AS repository,
    pr.author,
    COUNT(*) AS pr_count
  FROM
    pull_requests pr
  JOIN
    repositories r ON pr.repository_id = r.id
  GROUP BY
    r.id, pr.author
  ORDER BY
    pr_count DESC;
SQL

# Fetch Data with Pagination
def fetch_and_store_data(client, db, repo_owner, repo_name, days_range)
  (Date.today - days_range).to_s
  cursor = nil
  inserted_count = 0

  # Insert or get repository ID
  db.execute('INSERT OR IGNORE INTO repositories (owner, name) VALUES (?, ?)', [repo_owner, repo_name])
  repository_id = db.get_first_value('SELECT id FROM repositories WHERE owner = ? AND name = ?',
                                     [repo_owner, repo_name])

  # Check if we already have enough data for this time range
  oldest_needed_date = Date.today - days_range
  oldest_pr_date = db.get_first_value(
    'SELECT MIN(date(merged_at)) FROM pull_requests WHERE repository_id = ?',
    [repository_id]
  )

  if oldest_pr_date && Date.parse(oldest_pr_date) <= oldest_needed_date
    puts "Database already contains PRs dating back to #{oldest_pr_date}, which covers the required #{days_range} day range."
    return true
  end

  loop do
    puts "Fetching pull requests (cursor: #{cursor || 'start'})..."
    response = client.query(PullRequestsQuery, variables: { owner: repo_owner, name: repo_name, cursor: cursor })

    if response.errors.any?
      puts "GraphQL Errors: #{response.errors.messages}"
      return false
    end

    prs = response.data.repository.pull_requests
    pull_requests = prs.edges.map(&:node)

    # Filter pull requests by date range
    filtered_prs = pull_requests.select { |pr| Date.parse(pr.merged_at) >= oldest_needed_date }

    # Insert relevant data into SQLite with UPSERT pattern
    db.transaction do
      filtered_prs.each do |pr|
        db.execute(
          "INSERT INTO pull_requests (repository_id, pr_number, title, author, merged_at)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(repository_id, pr_number) DO UPDATE SET
           title = excluded.title,
           author = excluded.author,
           merged_at = excluded.merged_at",
          [repository_id, pr.number, pr.title, pr.author.login, pr.merged_at]
        )
        inserted_count += 1
      end
    end

    # Stop if no more pages or if all PRs are outside the date range
    break unless prs.page_info.has_next_page && !filtered_prs.empty?

    cursor = prs.page_info.end_cursor
  end

  puts "#{inserted_count} pull requests processed in SQLite database."
  true
end

# Generate HTML
def generate_html(db, repo_owner, repo_name, time_range, output_filename)
  contributors = db.execute(<<-SQL, [repo_owner, repo_name])
    SELECT
      pr.author,
      COUNT(*) AS pr_count
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

  total_prs = contributors.sum { |_, count| count }
  top_contributors = contributors.take(2)
  top_contributors_percentage = (top_contributors.sum { |_, count| count }.to_f / total_prs * 100).round
  risk_level = if top_contributors_percentage > 50
                 'High'
               elsif top_contributors_percentage > 30
                 'Medium'
               else
                 'Low'
               end

  template = <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <script src="https://cdn.tailwindcss.com"></script>
      <title>Lottery Factor</title>
    </head>
    <body class="bg-gray-900 text-gray-100 font-sans">
      <div class="max-w-md mx-auto mt-20 p-6 bg-gray-800 rounded-lg shadow-lg">
        <div class="flex items-center justify-between mb-4">
          <div class="text-lg font-semibold">🎟️ Lottery Factor</div>
          <span class="px-3 py-1 text-sm font-medium bg-red-500 text-white rounded-full"><%= risk_level %></span>
        </div>
        <p class="text-sm text-gray-400">
          The top <span class="font-bold"><%= top_contributors.length %></span> contributors of this repository have made <span class="font-bold"><%= top_contributors_percentage %>%</span> of all pull requests in the past <span class="font-bold"><%= time_range %></span> days.
        </p>
        <div class="flex mt-4 h-2 bg-gray-700 rounded-full overflow-hidden">
          <% contributors.each_with_index do |(_, count), index| %>
            <div style="background-color: <%= ['#FF5733', '#FFC300', '#DAF7A6', '#33FF57', '#3357FF'][index % 5] %>; width: <%= (count.to_f / total_prs * 100).round(2) %>%; display: inline-block;"></div>
          <% end %>
        </div>
        <table class="w-full mt-4 text-sm">
          <thead>
            <tr>
              <th class="text-left text-gray-400">Contributor</th>
              <th class="text-right text-gray-400">Pull Requests</th>
              <th class="text-right text-gray-400">% of Total</th>
            </tr>
          </thead>
          <tbody>
            <% contributors.each do |author, count| %>
              <tr>
                <td class="py-1"><%= author %></td>
                <td class="py-1 text-right"><%= count %></td>
                <td class="py-1 text-right"><%= (count.to_f / total_prs * 100).round %>%</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </body>
    </html>
  HTML

  renderer = ERB.new(template)
  html_output = renderer.result(binding)

  File.write(output_filename, html_output)
  puts "HTML file generated: #{output_filename}"
end

# Main Execution
begin
  data_updated = fetch_and_store_data(Client, db, repo_owner, repo_name, options[:time_range])

  if data_updated
    generate_html(db, repo_owner, repo_name, options[:time_range], options[:output])
  else
    puts 'Failed to update data, HTML not generated.'
  end
rescue SQLite3::Exception => e
  puts "SQLite error: #{e.message}"
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace.join("\n")
ensure
  db&.close
end
