# frozen_string_literal: true

# Pull request data fetcher
DataFetcher = Struct.new(:client, :database, keyword_init: true) do
  def fetch_and_store_data(repo_owner, repo_name, days_range)
    repository_id = database.get_repository_id(repo_owner, repo_name)

    prs_updated = if data_is_recent_enough?(repository_id, days_range)
                    puts "Database already contains PRs covering the required #{days_range} day range."
                    true
                  else
                    fetch_and_store_pull_requests(repo_owner, repo_name, repository_id, days_range)
                  end

    commits_updated = fetch_and_store_direct_commits(repo_owner, repo_name, repository_id, days_range)

    prs_updated && commits_updated
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

  def fetch_and_store_direct_commits(repo_owner, repo_name, repository_id, days_range)
    cursor = nil
    inserted_count = 0

    loop do
      puts "Fetching commits from default branch (cursor: #{cursor || 'start'})..."
      commit_history = client.fetch_direct_commits(repo_owner, repo_name, days_range, cursor)

      return false unless commit_history

      # Process all commits (with or without PR association)
      commits = commit_history.edges.map(&:node)

      count = database.insert_mainline_commits(repository_id, commits)
      inserted_count += count

      break unless commit_history.page_info.has_next_page

      cursor = commit_history.page_info.end_cursor
    end

    puts "#{inserted_count} commits processed in SQLite database."
    true
  end

  private

  def data_is_recent_enough?(repository_id, days_range)
    oldest_needed_date = Date.today - days_range
    oldest_pr_date = database.get_oldest_pr_date(repository_id)

    oldest_pr_date && Date.parse(oldest_pr_date) <= oldest_needed_date
  end
end
