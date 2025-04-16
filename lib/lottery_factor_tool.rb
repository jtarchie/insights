# frozen_string_literal: true

require_relative 'database'
require_relative 'github_client'
require_relative 'data_fetcher'
require_relative 'html_generator'

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
