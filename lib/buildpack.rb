require 'json'
require 'toml'
require_relative 'procfile'

class ProcfileBuildpack
  def detect(app_dir)
    has_procfile = File.exist?(File.join(app_dir, 'Procfile'))
    has_env_processes = !ENV['NEETO_DEPLOY_PROCESS_TYPE'].to_s.empty?
    
    if has_procfile || has_env_processes
      # Write build plan according to CNB spec
      plan = {
        "provides" => [{ "name" => "procfile" }],
        "requires" => [{ "name" => "procfile" }]
      }
      
      File.write(ENV['CNB_BUILD_PLAN_PATH'], JSON.generate(plan))
      true
    else
      false
    end
  end

  def build(layers_dir, platform_dir, app_dir)
    puts "-----> Discovering process types"

    procfile = if File.exist?(File.join(app_dir, 'Procfile'))
      procfile_path = File.join(app_dir, 'Procfile')
      puts "       Found Procfile in application root"
      Procfile.parse(File.read(procfile_path))
    elsif ENV['NEETO_DEPLOY_PROCESS_TYPE']
      puts "       Using process types from NEETO_DEPLOY_PROCESS_TYPE"
      begin
        processes = JSON.parse(ENV['NEETO_DEPLOY_PROCESS_TYPE'])
        procfile = Procfile.new
        processes.each do |type, command|
          procfile.insert(type, command)
        end
        procfile
      rescue JSON::ParserError => e
        puts "       Warning: Failed to parse NEETO_DEPLOY_PROCESS_TYPE: #{e.message}"
        Procfile.new
      end
    else
      Procfile.new
    end

    process_names = procfile.empty? ? '(none)' : procfile.processes.keys.join(', ')
    puts "       Process types -> #{process_names}"

      # Create a layer for process types
      process_layer_dir = File.join(layers_dir, 'processes')
      FileUtils.mkdir_p(process_layer_dir)
      
      # Write layer.toml for caching
      layer_toml = {
        "launch" => true,
        "build" => false,
        "cache" => false
      }
      File.write(File.join(process_layer_dir, 'layer.toml'), TOML.dump(layer_toml))

      # Read existing launch.toml if it exists (from other buildpacks)
      launch_toml_path = File.join(layers_dir, 'launch.toml')
      existing_launch = if File.exist?(launch_toml_path)
        TOML.load_file(launch_toml_path)
      else
        { "processes" => [] }
      end

      # Merge our processes with existing ones
      launch_config = procfile.to_launch
      existing_launch["processes"] ||= []
      
      # Add our processes, preserving any existing ones
      launch_config[:processes].each do |new_process|
        # Remove any existing process with the same type
        existing_launch["processes"].reject! { |p| p["type"] == new_process[:type] }
        # Add our process
        existing_launch["processes"] << {
          "type" => new_process[:type],
          "command" => new_process[:command],
          "args" => new_process[:args],
          "default" => new_process[:default],
          "working-dir" => new_process[:working_directory]
        }
      end

      # Write back the merged launch.toml
      File.write(launch_toml_path, TOML.dump(existing_launch))
      
      true
    rescue => e
      handle_error(e)
      exit 1
    end
  end

  private

  def handle_error(error)
    case error
    when Errno::ENOENT, Errno::EACCES
      puts "Error: Cannot read Procfile contents"
      puts "Please ensure the Procfile in the root of your application is a readable UTF-8 encoded file and try again."
      puts "\nUnderlying cause was: #{error.message}"
    else
      puts "Error: #{error.message}"
      puts error.backtrace
    end
  end

  def write_launch_toml(config)
    require 'toml'
    
    launch_toml = {
      "processes" => config[:processes].map do |process|
        {
          "type" => process[:type],
          "command" => process[:command],
          "args" => process[:args],
          "default" => process[:default],
          "working-dir" => process[:working_directory]
        }
      end
    }

    File.write("/cnb/launch.toml", TOML.dump(launch_toml))
  end
end
