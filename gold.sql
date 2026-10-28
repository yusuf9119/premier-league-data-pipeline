--  STAR SCHEMA 


-- dim_team
-- one row per team, both home and away link to this same table
create or replace table gold.dim_team as
select team_id, team_name, short_name, tla, stadium
from silver.teams;


-- dim_date
-- one row per date a match is on
create or replace table gold.dim_date as
select distinct
  to_number(to_char(match_date::date, 'YYYYMMDD')) as date_key,
  match_date::date as full_date,
  dayname(match_date) as day_name,
  monthname(match_date) as month_name,
  year(match_date) as year,
  dayname(match_date) in ('Sat', 'Sun') as is_weekend
from silver.matches;


-- fact_matches
-- only finished games, mostly ids and numbers
-- added points columns to make the league table easier later
create or replace table gold.fact_matches as
select
  match_id,
  to_number(to_char(match_date::date, 'YYYYMMDD')) as date_key,
  matchday,
  home_team_id,
  away_team_id,
  home_goals,
  away_goals,
  case
    when winner = 'HOME_TEAM' then 'H'
    when winner = 'AWAY_TEAM' then 'A'
    else 'D'
  end as result,
  case
    when winner = 'HOME_TEAM' then 3
    when winner = 'DRAW' then 1
    else 0
  end as home_points,
  case
    when winner = 'AWAY_TEAM' then 3
    when winner = 'DRAW' then 1
    else 0
  end as away_points
from silver.matches
where status = 'FINISHED';

-- should match the FINISHED count from silver
select count(*) from gold.fact_matches;

-- quick test the star schema joins work
select d.full_date, h.short_name as home, f.home_goals, f.away_goals, a.short_name as away
from gold.fact_matches f
join gold.dim_team h on f.home_team_id = h.team_id
join gold.dim_team a on f.away_team_id = a.team_id
join gold.dim_date d on f.date_key = d.date_key
order by d.full_date
limit 10;


-- ANALYSIS VIEWS 

-- league table
-- each match counts for 2 teams, so i make a row for the home side
-- and a row for the away side, stack them, then add up per team
create or replace view gold.vw_league_table as
with results as (
  select home_team_id as team_id, home_goals as scored, away_goals as conceded, home_points as points
  from gold.fact_matches
  union all
  select away_team_id, away_goals, home_goals, away_points
  from gold.fact_matches
)
select
  rank() over (order by sum(points) desc, sum(scored) - sum(conceded) desc, sum(scored) desc) as position,
  t.short_name as team,
  r.team_id,
  count(*) as played,
  sum(case when points = 3 then 1 else 0 end) as won,
  sum(case when points = 1 then 1 else 0 end) as drawn,
  sum(case when points = 0 then 1 else 0 end) as lost,
  sum(scored) as goals_for,
  sum(conceded) as goals_against,
  sum(scored) - sum(conceded) as goal_diff,
  sum(points) as points
from results r
join gold.dim_team t on r.team_id = t.team_id
group by t.short_name, r.team_id;

select * from gold.vw_league_table order by position;


-- table check (data quality)
-- compare my calculated table to the official standings from the api
-- uses the latest week's standings
create or replace view gold.vw_table_check as
select
  m.team,
  m.played as my_played,
  s.played as api_played,
  m.points as my_points,
  s.points as api_points,
  case when m.points = s.points and m.played = s.played then 'OK' else 'MISMATCH' end as status
from gold.vw_league_table m
join silver.standings s on m.team_id = s.team_id
where s.snapshot_date = (select max(snapshot_date) from silver.standings);

-- hoping for all OK
select * from gold.vw_table_check order by status, team;


-- home vs away
-- is there a home advantage?
create or replace view gold.vw_home_vs_away as
select
  count(*) as games,
  round(100 * sum(case when result = 'H' then 1 else 0 end) / count(*), 1) as home_win_pct,
  round(100 * sum(case when result = 'D' then 1 else 0 end) / count(*), 1) as draw_pct,
  round(100 * sum(case when result = 'A' then 1 else 0 end) / count(*), 1) as away_win_pct,
  round(avg(home_goals), 2) as avg_home_goals,
  round(avg(away_goals), 2) as avg_away_goals
from gold.fact_matches;

select * from gold.vw_home_vs_away;


-- team form, last 5 games
-- same home/away trick but turned into W/D/L for each team
create or replace view gold.vw_team_form as
with games as (
  select f.home_team_id as team_id, d.full_date,
    case when f.home_points = 3 then 'W' when f.home_points = 1 then 'D' else 'L' end as res
  from gold.fact_matches f
  join gold.dim_date d on f.date_key = d.date_key
  union all
  select f.away_team_id, d.full_date,
    case when f.away_points = 3 then 'W' when f.away_points = 1 then 'D' else 'L' end
  from gold.fact_matches f
  join gold.dim_date d on f.date_key = d.date_key
),
last5 as (
  select *, row_number() over (partition by team_id order by full_date desc) as rn
  from games
)
select
  t.short_name as team,
  listagg(res, ' ') within group (order by full_date) as last_5,
  sum(case when res = 'W' then 3 when res = 'D' then 1 else 0 end) as form_points
from last5 l
join gold.dim_team t on l.team_id = t.team_id
where rn <= 5
group by t.short_name;

select * from gold.vw_team_form order by form_points desc;