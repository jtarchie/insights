# frozen_string_literal: true

require 'erb'

# HTML report generator
HtmlGenerator = Struct.new(:database, :top_display_count, keyword_init: true) do
  def initialize(database:, top_display_count: 5)
    super
  end

  def generate(repo_owner, repo_name, time_range, output_filename)
    contributors = database.get_contributors(repo_owner, repo_name)
    yolo_coders = database.get_yolo_coders(repo_owner, repo_name, time_range)

    report_data = calculate_report_data(contributors, yolo_coders, time_range, repo_owner, repo_name)
    html_output = render_template(report_data)

    File.write(output_filename, html_output)
    puts "HTML file generated: #{output_filename}"
  end

  private

  def calculate_report_data(contributors, yolo_coders, time_range, repo_owner, repo_name)
    # Calculate lottery factor data
    total_prs = contributors.sum { |_, count| count }
    top_contributors = contributors.take(2)
    top_contributors_percentage = begin
      (top_contributors.sum { |_, count| count }.to_f / total_prs * 100).round
    rescue StandardError
      0
    end
    risk_level = calculate_risk_level(top_contributors_percentage)

    # Calculate YOLO coders data
    total_yolo_commits = yolo_coders.sum { |_, count, _| count }
    yolo_coder_count = yolo_coders.length

    {
      contributors: contributors,
      total_prs: total_prs,
      top_contributors: top_contributors,
      top_contributors_percentage: top_contributors_percentage,
      risk_level: risk_level,
      time_range: time_range,
      top_display_count: top_display_count,
      yolo_coders: yolo_coders,
      total_yolo_commits: total_yolo_commits,
      yolo_coder_count: yolo_coder_count,
      repo_owner: repo_owner,
      repo_name: repo_name
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
        <title>Repository Insights</title>
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
                      <a href="https://github.com/<%= data[:repo_owner] %>/<%= data[:repo_name] %>/pulls?q=author:<%= author %>" target="_blank" class="flex items-center gap-2">
                        <img src="https://github.com/<%= author %>.png" alt="<%= author %>" class="w-6 h-6 rounded-full">
                        <span><%= author %></span>
                      </a>
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

        <!-- YOLO Coders Card -->
        <div class="max-w-md mx-auto mt-6 p-6 bg-gray-100 dark:bg-gray-800 rounded-lg shadow-lg transition-colors duration-200">
          <div class="flex items-center justify-between mb-4">
            <div class="text-lg font-semibold">✋ YOLO Coders</div>
          </div>

          <p class="text-sm text-gray-600 dark:text-gray-400">
            <span class="font-bold"><%= data[:yolo_coder_count] %></span> contributors have pushed <span class="font-bold"><%= data[:total_yolo_commits] %></span> commits directly to the main branch in the last <span class="font-bold"><%= data[:time_range] %></span> days.
          </p>

          <table class="w-full mt-4 text-sm">
            <thead>
              <tr>
                <th class="text-left text-gray-600 dark:text-gray-400">Contributor</th>
                <th class="text-center text-gray-600 dark:text-gray-400">Sha</th>
                <th class="text-right text-gray-600 dark:text-gray-400">Pushed</th>
              </tr>
            </thead>
            <tbody>
              <% data[:yolo_coders].each do |author, count, shas| %>
                <tr>
                  <td class="py-1">
                    <div class="flex items-center gap-2">
                      <a href="https://github.com/<%= data[:repo_owner] %>/<%= data[:repo_name] %>/commits?author=<%= author %>" target="_blank" class="flex items-center gap-2">
                        <img src="https://github.com/<%= author %>.png" alt="<%= author %>" class="w-6 h-6 rounded-full">
                        <span><%= author %></span>
                      </a>
                    </div>
                  </td>
                  <td class="py-1 text-center">
                    <% first_sha = shas.split(',').first %>
                    <a href="https://github.com/<%= data[:repo_owner] %>/<%= data[:repo_name] %>/commit/<%= first_sha %>" target="_blank" class="text-blue-500 hover:underline"><%= first_sha[0..6] %></a>
                  </td>
                  <td class="py-1 text-right"><%= count %> commit<%= count > 1 ? 's' : '' %></td>
                </tr>
              <% end %>
            </tbody>
          </table>

          <p class="mt-4 text-sm text-gray-600 dark:text-gray-400">
            <a href="https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/about-pull-requests" target="_blank" class="text-blue-500 hover:underline">Learn more</a> about why pull requests are a better way to contribute.
          </p>
        </div>
      </body>
      </html>
    HTML
  end
end
