# frozen_string_literal: true

require 'date'
require 'graphql/client'
require 'graphql/client/http'

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

  # Updated direct commits query that also fetches associated PR information
  DirectCommitsQuery = Client.parse <<-'GRAPHQL'
    query($owner: String!, $repo: String!, $since: GitTimestamp!, $afterCursor: String) {
      repository(owner: $owner, name: $repo) {
        defaultBranchRef {
          target {
            ... on Commit {
              history(since: $since, after: $afterCursor) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                edges {
                  node {
                    oid
                    author {
                      user {
                        login
                      }
                    }
                    committedDate
                    associatedPullRequests(first: 1) {
                      nodes {
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
            }
          }
        }
      }
    }
  GRAPHQL

  def fetch_pull_requests(owner, name, cursor = nil)
    response = Client.query(PullRequestsQuery, variables: { owner: owner, name: name, cursor: cursor })

    if response.errors.any?
      puts "GraphQL Errors: #{response.errors}"
      return nil
    end

    response.data.repository.pull_requests
  end

  def fetch_direct_commits(owner, name, since_days = 30, cursor = nil)
    since_date = (Date.today - since_days).to_time.iso8601

    response = Client.query(DirectCommitsQuery, variables: {
                              owner: owner,
                              repo: name,
                              since: since_date,
                              afterCursor: cursor
                            })

    if response.errors.any?
      puts "GraphQL Errors: #{response.errors.messages}"
      return nil
    end

    response.data.repository.default_branch_ref.target.history
  end
end
