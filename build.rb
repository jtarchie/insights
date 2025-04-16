# frozen_string_literal: true

require_relative './lib/lottery_factor_tool'
require 'optparse'

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
