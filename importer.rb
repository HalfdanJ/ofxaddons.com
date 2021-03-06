require './github_api'
require './models'
require 'colorize'
require 'pony'

class Importer

  # TODO: this doesn't seem like it actually does anything since it
  #       queries for is_fork:false, but then only does things to
  #       repos where is_fork must be true
  # def self.update_source_for_uncategorized_repos
  #   repos = Repo.all :not_addon => false, :is_fork => false, :category => nil, :deleted => false
  #   count = repos.length
  #   repos.each_with_index do |repo,i|
  #     puts "[#{i+1}/#{count}] finding source for #{repo.github_slug}"
  #     if repo.is_fork
  #       repo.update_ancestry
  #       if repo.source_repo
  #         puts "source: #{repo.source_repo.github_slug} [not_addon: #{repo.source_repo.not_addon}]"
  #         repo.not_addon = repo.source_repo.not_addon
  #         repo.save
  #       else
  #         puts "source unknown"
  #       end
  #     end
  #   end
  # end

  def self.update_forks
    repos = Repo.all :not_addon => false, :is_fork => false, :deleted => false, :category.not => nil, :has_forks => true

    count = repos.length
    repos.each_with_index do |source_repo,i|

	  if !source_repo.github_pushed_at
	    puts "[#{i+1}/#{count}] #{source_repo.github_slug} does not have a pushed at string, cannot query forks".red
	    next
	  end

      puts "[#{i+1}/#{count}] finding source for #{source_repo.github_slug}"

   	  url = "https://api.github.com/repos/#{source_repo.github_slug}/forks?#$auth_params"
	  puts "fetching forks: #{ url }"
	  result = HTTParty.get(url)
	  if result.success?
	  	result.each do |r|

          # Shouldn't need this since generally forks are not renamed
          #           if(!r["name"].start_with?('ofx'))
          #   	        puts "Repo #{r["name"]} doesn't start with 'ofx', not saving".red
          # 	        next
          # 	      end

		  if r["pushed_at"] && DateTime.parse(r["pushed_at"]) > DateTime.parse(source_repo.github_pushed_at)
            puts "fork pushed at #{DateTime.parse(r["pushed_at"])}, source repo #{DateTime.parse(source_repo.github_pushed_at)}. updating"
            fork_repo = Repo.first(:owner => r['owner']['login'], :name => r['name'])
            if !fork_repo
              # create a new record
              puts "creating fork:\t".green + "#{ r['owner']['login'] }/#{ r['name'] }"
              #puts "creating fork".green
              Repo.create_from_json(r)
            else
              # update this record
              puts "updating fork:\t".green + "#{ r['owner']['login'] }/#{ r['name'] }"
              fork_repo.update_from_json(r)
            end
          else
		  	puts "no more recent commits than source, skipping ".red + "#{ r['owner']['login'] }/#{ r['name'] }"
          end
	    end
	  end
	end
  end

  # TODO: fixme, need to be updated to work with the Github V3 api
  # def self.update_issues_for_all_repos
  #   count = Repo.count(:not_addon => false, :is_fork => false, :category.not => nil)
  #   Repo.all(:not_addon => false, :is_fork => false, :deleted => false, :category.not => nil).each_with_index do |repo, i|
  #     puts "[#{i+1}/#{count}] Updating Issues for #{repo.name}"
  #     repo.issues = repo.get_issues
  #     repo.save
  #   end
  # end

  def self.send_report(msg)
    Pony.mail :to => ['greg.borenstein@gmail.com', 'james@jamesgeorge.org', 'james@virtualjames.com'],
    :from => 'greg.borenstein@gmail.com',
    :subject => 'ofxaddons report',
    :body => msg,
    :via => :smtp,
    :via_options => {
      :address   => 'smtp.sendgrid.net',
      :port   => '25',
      :user_name   => ENV['SENDGRID_USERNAME'],
      :password   => ENV['SENDGRID_PASSWORD'],
      :authorization => :plain,
      :domain => ENV['SENDGRID_DOMAIN']
    }
  end


  def self.skipping_because(repo_json, message)
    puts "skipping:\t".red + repo_json['full_name'] + "\treason: #{ message }"
  end

  def self.import_from_search(term)
  	puts "doing search..."

    GithubApi::search_repositories_pager(term) do |response|
      unless response.success?
        puts "Bad response #{ response.code }"
        next
      end

      if repositories = response.parsed_response["items"]
        repositories.each do |r|

          unless r["pushed_at"]
            skipping_because(r, "no commits")
            next
          end

          unless r["name"].match(/^ofx/i)
            skipping_because(r, "name doesn't start with 'ofx'")
            next
          end

          repo = Repo.first(:owner => r['owner']['login'], :name => r['name'])

          if repo && repo.not_addon
            skipping_because(r, "not an addon")
            next
          end

          if repo
            # update this record
            puts "updating: #{ r['full_name'] }"
            repo.update_from_json(r)
          else
            # create a new record
            puts "creating: #{ r['full_name'] }"
            Repo.create_from_json(r)
          end
        end
      else
        puts "Search returned no repos".red
      end
    end
  end

  def self.purge_deleted_repos

    repos = Repo.all :not_addon => false
    count = repos.length
    puts "checking for deleted repos"

    repos.each_with_index do |repo,i|
      url = "https://api.github.com/repos/#{repo.github_slug}?#$auth_params"
      result = HTTParty.get(url)

      #puts "repo #{i} : #{url}"
      was_deleted = repo.deleted
      if !result.success? || result["message"].eql?("Not Found")
        puts "[#{i+1}/#{count}] https://api.github.com/repos/#{repo.github_slug} was deleted".red
        repo.deleted = true
      else
        puts "[#{i+1}/#{count}] https://api.github.com/repos/#{repo.github_slug} still live"
        repo.deleted = false
      end

      if repo.deleted != was_deleted
        puts "-saving deletion change-"
        repo.save
      end

    end
  end
end
