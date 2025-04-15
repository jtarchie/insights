# frozen_string_literal: true

require 'graphql/client'
require 'graphql/client/http'
require 'sqlite3'
require 'date'
require 'optparse'
require 'erb'

# Main application class that coordinates the workflow
class LotteryFactorTool
  def initialize(options)
    @options = options
    @repo_owner, @repo_name = options[:repo].split('/')
    @database = options[:database]
    @time_range = options[:time_range]
    @output = options[:output] || "#{@repo_owner}-#{@repo_name}-lottery.html"
    @top_display_count = options[:top_display_count] || 5
  end

  def run
    validate_repository

    begin
      db = Database.new(@database)
      github_client = GitHubClient.new

      data_fetcher = DataFetcher.new(client: github_client, database: db)
      data_updated = data_fetcher.fetch_and_store_data(@repo_owner, @repo_name, @time_range)

      if data_updated
        html_generator = HtmlGenerator.new(database: db, top_display_count: @top_display_count)
        html_generator.generate(@repo_owner, @repo_name, @time_range, @output)
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
  end

  private

  def validate_repository
    return unless !@repo_owner || !@repo_name

    puts "Error: Invalid repository format. Use 'username/repo'."
    exit 1
  end
end

# GitHub GraphQL API client
class GitHubClient
  # Create an HTTP adapter for GraphQL
  HTTP = GraphQL::Client::HTTP.new('https://api.github.com/graphql') do
    def headers(_context)
      { 'Authorization' => "Bearer #{ENV['GITHUB_TOKEN']}" }
    end
  end

  # Load the GraphQL schema
  Schema = GraphQL::Client.load_schema(HTTP)

  # Create a client instance
  Client = GraphQL::Client.new(schema: Schema, execute: HTTP)

  # Define the query as a constant at the class level
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

  def fetch_pull_requests(owner, name, cursor = nil)
    response = Client.query(PullRequestsQuery, variables: { owner: owner, name: name, cursor: cursor })

    if response.errors.any?
      puts "GraphQL Errors: #{response.errors.messages}"
      return nil
    end

    response.data.repository.pull_requests
  end
end

# Database operations handler
class Database
  def initialize(database_path)
    @db = SQLite3::Database.new(database_path)
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
  end

  def get_repository_id(owner, name)
    @db.execute('INSERT OR IGNORE INTO repositories (owner, name) VALUES (?, ?)', [owner, name])
    @db.get_first_value('SELECT id FROM repositories WHERE owner = ? AND name = ?', [owner, name])
  end

  def get_oldest_pr_date(repository_id)
    @db.get_first_value(
      'SELECT MIN(date(merged_at)) FROM pull_requests WHERE repository_id = ?',
      [repository_id]
    )
  end

  def insert_pull_requests(repository_id, pull_requests)
    count = 0
    @db.transaction do
      pull_requests.each do |pr|
        @db.execute(
          "INSERT INTO pull_requests (repository_id, pr_number, title, author, merged_at)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(repository_id, pr_number) DO UPDATE SET
           title = excluded.title,
           author = excluded.author,
           merged_at = excluded.merged_at",
          [repository_id, pr.number, pr.title, pr.author.login, pr.merged_at]
        )
        count += 1
      end
    end
    count
  end

  def get_contributors(owner, name)
    @db.execute(<<-SQL, [owner, name])
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
  end
end

# Pull request data fetcher
DataFetcher = Struct.new(:client, :database, keyword_init: true) do
  def fetch_and_store_data(repo_owner, repo_name, days_range)
    repository_id = database.get_repository_id(repo_owner, repo_name)

    if data_is_recent_enough?(repository_id, days_range)
      puts "Database already contains PRs covering the required #{days_range} day range."
      return true
    end

    fetch_and_store_pull_requests(repo_owner, repo_name, repository_id, days_range)
  end

  private

  def data_is_recent_enough?(repository_id, days_range)
    oldest_needed_date = Date.today - days_range
    oldest_pr_date = database.get_oldest_pr_date(repository_id)

    oldest_pr_date && Date.parse(oldest_pr_date) <= oldest_needed_date
  end

  def fetch_and_store_pull_requests(repo_owner, repo_name, repository_id, days_range)
    cursor = nil
    inserted_count = 0
    oldest_needed_date = Date.today - days_range

    loop do
      puts "Fetching pull requests (cursor: #{cursor || 'start'})..."
      prs = client.fetch_pull_requests(repo_owner, repo_name, cursor)

      return false unless prs

      pull_requests = prs.edges.map(&:node)
      filtered_prs = pull_requests.select { |pr| Date.parse(pr.merged_at) >= oldest_needed_date }

      count = database.insert_pull_requests(repository_id, filtered_prs)
      inserted_count += count

      break unless prs.page_info.has_next_page && !filtered_prs.empty?

      cursor = prs.page_info.end_cursor
    end

    puts "#{inserted_count} pull requests processed in SQLite database."
    true
  end
end

# HTML report generator
HtmlGenerator = Struct.new(:database, :top_display_count, keyword_init: true) do
  def initialize(database:, top_display_count: 5)
    super
  end

  def generate(repo_owner, repo_name, time_range, output_filename)
    contributors = database.get_contributors(repo_owner, repo_name)

    report_data = calculate_report_data(contributors, time_range)
    html_output = render_template(report_data)

    File.write(output_filename, html_output)
    puts "HTML file generated: #{output_filename}"
  end

  private

  def calculate_report_data(contributors, time_range)
    total_prs = contributors.sum { |_, count| count }
    top_contributors = contributors.take(2)
    top_contributors_percentage = (top_contributors.sum { |_, count| count }.to_f / total_prs * 100).round
    risk_level = calculate_risk_level(top_contributors_percentage)

    {
      contributors: contributors,
      total_prs: total_prs,
      top_contributors: top_contributors,
      top_contributors_percentage: top_contributors_percentage,
      risk_level: risk_level,
      time_range: time_range,
      top_display_count: top_display_count
    }
  end

  def calculate_risk_level(percentage)
    if percentage > 50
      'High'
    elsif percentage > 30
      'Medium'
    else
      'Low'
    end
  end

  def render_template(data)
    template_path = File.join(File.dirname(__FILE__), 'templates/lottery_report.html.erb')
    if File.exist?(template_path)
      template = File.read(template_path)
      renderer = ERB.new(template)
    else
      # Fallback to inline template if external template is not available
      renderer = ERB.new(inline_template)
    end
    renderer.result(binding)
  end

  def risk_color(level)
    case level
    when 'High'
      'red-500'
    when 'Medium'
      'yellow-500'
    else
      'green-500'
    end
  end

  def inline_template
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <script src="https://cdn.tailwindcss.com"></script>
        <title>Lottery Factor</title>
        <style>
          .color-1 { background-color: #FF5733; }
          .color-2 { background-color: #FFC300; }
          .color-3 { background-color: #DAF7A6; }
          .color-4 { background-color: #33FF57; }
          .color-5 { background-color: #3357FF; }
          .color-others { background-color: #808080; }
        </style>
      </head>
      <body class="bg-white dark:bg-gray-900 text-gray-800 dark:text-gray-100 font-sans transition-colors duration-200">
        <div class="max-w-md mx-auto mt-20 p-6 bg-gray-100 dark:bg-gray-800 rounded-lg shadow-lg transition-colors duration-200">
          <div class="flex items-center justify-between mb-4">
            <div class="text-lg font-semibold">🎟️ Lottery Factor</div>
            <div class="flex gap-2">
              <span class="px-3 py-1 text-sm font-medium bg-<%= risk_color(data[:risk_level]) %> text-white rounded-full"><%= data[:risk_level] %></span>
            </div>
          </div>
          <p class="text-sm text-gray-600 dark:text-gray-400">
            The top <span class="font-bold"><%= data[:top_contributors].length %></span> contributors of this repository have made <span class="font-bold"><%= data[:top_contributors_percentage] %>%</span> of all pull requests in the past <span class="font-bold"><%= data[:time_range] %></span> days.
          </p>
          <div class="flex mt-4 h-2 bg-gray-300 dark:bg-gray-700 rounded-full overflow-hidden">
            <% displayed_contributors = data[:contributors].take(data[:top_display_count]) %>
            <% other_contributors = data[:contributors].drop(data[:top_display_count]) %>

            <% displayed_contributors.each_with_index do |(_, count), index| %>
              <div class="color-<%= (index % 5) + 1 %>" style="width: <%= (count.to_f / data[:total_prs] * 100).round(2) %>%; display: inline-block;"></div>
            <% end %>

            <% if other_contributors.any? %>
              <div class="color-others" style="width: <%= (other_contributors.sum { |_, c| c }.to_f / data[:total_prs] * 100).round(2) %>%; display: inline-block;"></div>
            <% end %>
          </div>
          <table class="w-full mt-4 text-sm">
            <thead>
              <tr>
                <th class="text-left text-gray-600 dark:text-gray-400">Contributor</th>
                <th class="text-right text-gray-600 dark:text-gray-400">Pull Requests</th>
                <th class="text-right text-gray-600 dark:text-gray-400">% of Total</th>
              </tr>
            </thead>
            <tbody>
              <% displayed_contributors.each do |author, count| %>
                <tr>
                  <td class="py-1">
                    <div class="flex items-center gap-2">
                      <img src="https://github.com/<%= author %>.png" alt="<%= author %>" class="w-6 h-6 rounded-full">
                      <span><%= author %></span>
                    </div>
                  </td>
                  <td class="py-1 text-right"><%= count %></td>
                  <td class="py-1 text-right"><%= (count.to_f / data[:total_prs] * 100).round %>%</td>
                </tr>
              <% end %>

              <% if other_contributors.any? %>
                <tr class="border-t border-gray-300 dark:border-gray-700">
                  <td class="py-2">
                    <div class="flex items-center gap-2">
                      <div class="w-6 h-6 rounded-full bg-gray-300 dark:bg-gray-600 flex items-center justify-center text-xs">+<%= other_contributors.length %></div>
                      <span>Other Contributors</span>
                    </div>
                  </td>
                  <td class="py-2 text-right"><%= other_contributors.sum { |_, c| c } %></td>
                  <td class="py-2 text-right"><%= (other_contributors.sum { |_, c| c }.to_f / data[:total_prs] * 100).round %>%</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </body>
      </html>
    HTML
  end
end

# Command-line argument parser
class CommandLineParser
  def self.parse(args)
    options = {}

    parser = OptionParser.new do |opts|
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

      opts.on('--top-display COUNT', Integer,
              'Number of top contributors to display individually (default: 5)') do |count|
        options[:top_display_count] = count
      end
    end

    parser.parse!(args)

    # Validate Required Arguments
    unless options[:repo] && options[:database] && options[:time_range]
      puts 'Error: Missing required arguments.'
      puts parser.help
      exit 1
    end

    options
  end
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  options = CommandLineParser.parse(ARGV)
  tool = LotteryFactorTool.new(options)
  tool.run
end
