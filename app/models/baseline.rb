class Baseline < ActiveRecord::Base
  include Redmine::SafeAttributes
  include Schedulable
  unloadable

  belongs_to :project
  has_many :baseline_issues, dependent: :destroy
  has_many :baseline_versions, dependent: :destroy

  validates :name, :due_date, :presence => true


  before_create {update_baseline_status("#{l(:label_old_baseline)}", project_id)}
  after_destroy {update_baseline_status("#{l(:label_current_baseline)}", project_id)}

  acts_as_customizable

  safe_attributes 'name',
  'description',
  'due_date'

  def create_versions versions, versions_to_exclude, update_estimated_hours
    unless versions.nil?
      versions.each do |version|
        versions_to_exclude.nil? ? exclude = false : exclude =  versions_to_exclude.include?(version.id)
        if version.closed? && update_estimated_hours == "1"
        baseline_versions.create(original_version_id: version.id, effective_date: version.get_end_date(self.id), start_date: version.start_date || version.get_start_date(self.id), name: version.name, exclude: exclude)  
        else
        baseline_versions.create(original_version_id: version.id, effective_date: version.due_date, start_date: version.start_date || version.get_start_date(self.id), name: version.name, exclude: exclude)
        #baseline_versions.create(original_version_id: version.id, effective_date: version.get_end_date(self.id), start_date: version.get_start_date(self.id), name: version.name, exclude: exclude)
        end
      end
    end
  end

  def create_issues issues, update_estimated_hours
    unless issues.nil?
      issues.each do |issue|
        baseline_issue = BaselineIssue.new(original_issue_id: issue.id, done_ratio: issue.done_ratio, status: issue.status.name, due_date: issue.due_date, start_date: issue.start_date || issue.created_on, exclude: false)

        baseline_version = self.baseline_versions.find_by_original_version_id(issue.fixed_version_id)
        unless baseline_version.nil?
          baseline_issue.baseline_version_id = baseline_version.id
          baseline_issue.exclude = baseline_version.exclude
        end

        if update_estimated_hours == "1"
          puts issue.status.name
          if issue.status.name == "Closed"
            baseline_issue.estimated_hours = issue.spent_hours
            if issue.due_date.nil?
              issue.time_entries.empty? ? baseline_issue.due_date = issue.updated_on.to_date : baseline_issue.due_date = issue.time_entries.maximum('spent_on')
            end  
          else
            baseline_issue.estimated_hours = issue.estimated_hours || 0
            #issue.due_date.nil? ? baseline_issue.due_date = issue.time_entries.maximum('spent_on') : baseline_issue.due_date = issue.due_date
          end
        else
          baseline_issue.estimated_hours = issue.estimated_hours || 0
          if issue.status.name == "Closed"
            if issue.due_date.nil?
              issue.time_entries.empty? ? baseline_issue.due_date = issue.updated_on.to_date : baseline_issue.due_date = issue.time_entries.maximum('spent_on')
            end
          end
          # if issue.done_ratio == 100 || issue.status.name == "Rejected"
          #   issue.time_entries.empty? ? baseline_issue.due_date = issue.updated_on.to_date : baseline_issue.due_date = issue.time_entries.maximum('spent_on')
          # else
          #   issue.due_date.nil? ? baseline_issue.due_date = issue.time_entries.maximum('spent_on') : baseline_issue.due_date = issue.due_date
          # end
        end 

        baseline_issue.save
        baseline_issues << baseline_issue
        
      end
    end
  end

  def versions_to_exclude operator, selected_target_versions, project_id
    target_versions = []
    all_versions = Project.find(project_id).versions.map(&:id)
    unless selected_target_versions.nil?
      target_versions = selected_target_versions.collect{|v| v.to_i}
    end
    
    if operator == "is"
      all_versions - target_versions #All the other not selected versions are excluded.
    elsif operator == "is not"
      target_versions
    elsif operator == "any"
      target_versions
    elsif operator == "none"
      all_versions
    end
  end

  #Returns the excluded versions from this baseline
  def get_excluded_versions
    baseline_versions.where(exclude: true).map(&:original_version_id)
  end

  def get_targeted_versions
    baseline_versions.where(exclude: false).map(&:original_version_id)
  end

  def update_baseline_status status, project_id
    project = Project.find(project_id) 
    baseline = project.baselines.last 
    if baseline 
      baseline.state = status 
      baseline.save
    end
  end

  def end_date
    due_date
  end

  #EVM Metrics----------------------

  #Earned Value (EV)
  def earned_value
    project = Project.find(project_id)
    project.earned_value(self.id)
  end

  #Actual Cost (AC)
  def actual_cost
    project = Project.find(project_id)
    project.actual_cost(self.id)
  end

  #Schedule Performance Index (SPI)
  def schedule_performance_index 
    if self.planned_value != 0
      earned_value.to_f / self.planned_value
    else
      return 0
    end
  end

  #Cost Performance Index (CPI)
  def cost_performance_index
    if actual_cost != 0
      earned_value.to_f / actual_cost
    else
      return 0
    end
  end

  #Schedule Variance (SV)
  def schedule_variance
    earned_value - planned_value
  end

  #Cost Variance (CV)
  def cost_variance
    earned_value - self.actual_cost
  end

  #Budget at Completion (BAC)
  def budget_at_completion
    planned_value_at_completion
  end

  #Estimate at Completion (EAC$) Yaxis
  #http://www.pmknowledgecenter.com/node/166
  def estimate_at_completion_cost
    actual_cost + (budget_at_completion - earned_value) / cost_performance_index
  end

  #Estimate to complete (ETC)
  def estimate_to_complete
    estimate_at_completion_cost - actual_cost
  end

  #Variance at Completion (VAC)
  def variance_at_completion
    budget_at_completion - estimate_at_completion_cost
  end

  # % Completed
  def completed_actual
    actual_cost.to_f / estimate_at_completion_cost
  end

  #Planned Duration (PD)
  def planned_duration
    planned_value_by_week.count - 1 
  end

  #Actual duration (AT)
  def actual_duration
    planned_value_by_week.select { |key,value| key <= Date.today }.count
  end

  #Earned Duration (ED)
  # def earned_duration
  #   actual_duration * schedule_performance_index
  # end

  #Estimate at Completion Duration (EACt)
  #Method using Earned Duration (ED) from http://www.pmknowledgecenter.com/dynamic_scheduling/control/earned-value-management-forecasting-time
  #(max(PD, AT) - ED) and ED is earned duration can get by ED = AT * SPI
  # def estimate_at_completion_duration
  #   ( [planned_duration, actual_duration].max ) - earned_duration
  # end

  #Earned Schedule (ES) from http://www.pmknowledgecenter.com/node/163
  def earned_schedule
    ev = earned_value.round               #Current Earned Value
    pv_line = planned_value_by_week         #Planned value by week to see in what week EV is the same as PV.

    week = pv_line.first[0]                 #PVt week
    next_week = pv_line.first[0]            #PVt+1 week

    previous_value = 0                      #Temp PVt value for loop
    previous_key = pv_line.first[0]         #Temp PVt week for loop  

    pv_line.each do |key, value|
      # puts "#{previous_value} >= #{ev} <  #{value}"
      if( ev >= previous_value.round && ev < value.round)  #Each key is a week, in what week does the EV equal to PV?
        # puts "#{previous_value} >= #{ev} <  #{value}"
        # puts "Yes!"
        week = previous_key
        next_week = key
      elsif( ev == previous_value.round && ev == value.round) #THIS elseif is here when both are equal until the end of the project, e.g. when the project is finished.
        # puts "Yes! Equal"
        week =  key
        next_week = key
      end
      previous_key = key
      previous_value = value.round
    end

    pv_t = pv_line[week]                   #PVt value
    pv_t_next = pv_line[next_week]         #PVt+1 value

    num_of_weeks = pv_line.keys[0..pv_line.keys.index(week)].size - 1  #Get num of weeks until "week", t is number of weeks.
    
    # puts week
    # puts "EV = #{ev}"
    # puts "PVt+1 = #{pv_line[next_week]}"
    # puts "PVt = #{pv_line[week]}"
    # puts "Number of weeks #{num_of_weeks}"
    # puts "planned_duration = #{planned_duration}"

    # puts "ES #{num_of_weeks + ((ev - pv_line[week]) / (pv_line[next_week] - pv_line[week]))}"

    if  (pv_line[next_week] - pv_line[week]) == 0 #Prevent from divide by zero, when values are equal.
      num_of_weeks                                #This means that the line is flat. So use the previous value because (EV >= PVt and EV < PVt+1).
    else
      num_of_weeks + ((ev - pv_line[week]).to_f / (pv_line[next_week] - pv_line[week]))
    end
  end

  #Estimate at Completion Duration (EACt)
  #Method using Earned Schedule (ES) from http://www.pmknowledgecenter.com/dynamic_scheduling/control/earned-value-management-forecasting-time
  def estimate_at_completion_duration
    # puts "EACt #{planned_duration - earned_schedule}"
    return planned_duration - earned_schedule
  end

  def actual_cost_forecast_line
    [[ Time.now.beginning_of_week, actual_cost ], [ estimate_at_completion_duration.week.from_now.beginning_of_week, estimate_at_completion_cost ]] #The estimated line after actual cost
  end

  def earned_value_forecast_line
    project = Project.find(project_id)
    [[ Time.now.beginning_of_week, earned_value ], [ estimate_at_completion_duration.week.from_now.beginning_of_week, budget_at_completion]]
  end

  #End date for top lines. Detects if it is an old project, so it does not go beyond baseline due_date.
  def end_date_for_top_line
    project = Project.find(project_id)

    if(end_date < Date.today) #If it is an old project.
      end_date_for_top_line = [project.get_end_date(self.id).beginning_of_week, self.end_date.beginning_of_week].max
    else
      end_date_for_top_line = [project.get_end_date(self.id).beginning_of_week, self.end_date.beginning_of_week, estimate_at_completion_duration.week.from_now].max
    end
  end

  #Ceiling line for the chart to indicate the project BAC value.
  def bac_top_line
    bac = budget_at_completion
    bac_top_line = [[start_date.beginning_of_week, bac],[end_date_for_top_line, bac]] 
  end

  #Ceiling line for the chart to indicate the project EAC value.
  def eac_top_line
    eac = estimate_at_completion_cost
    eac_top_line = [[start_date.beginning_of_week, eac],[end_date_for_top_line, eac]]
  end

end
