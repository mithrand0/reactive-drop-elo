-- MySQL dump

SET NAMES utf8;
SET time_zone = '+00:00';
SET foreign_key_checks = 0;

SET NAMES utf8mb4;

CREATE DATABASE `elo` /*!40100 DEFAULT CHARACTER SET utf8mb4 */;
USE `elo`;

CREATE TABLE `map_score` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `map_name` varchar(255) NOT NULL,
  `challenge` varchar(255) NOT NULL,
  `retry_limit` smallint(5) unsigned DEFAULT 3,
  `score` smallint(5) unsigned NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `map_name_challenge` (`map_name`,`challenge`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE `player_history` (
  `steamid` bigint(20) unsigned NOT NULL,
  `elo` smallint(6) unsigned NOT NULL,
  `gain` smallint(6) NOT NULL,
  `map_challenge` int(11) unsigned NOT NULL,
  `difficulty` tinyint(3) unsigned NOT NULL,
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  KEY `steamid` (`steamid`),
  KEY `map_challenge` (`map_challenge`),
  CONSTRAINT `player_history_ibfk_2` FOREIGN KEY (`steamid`) REFERENCES `player_score` (`steamid`),
  CONSTRAINT `player_history_ibfk_3` FOREIGN KEY (`map_challenge`) REFERENCES `map_score` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE `player_score` (
  `steamid` bigint(20) unsigned NOT NULL,
  `name` varchar(255) DEFAULT NULL,
  `elo` smallint(6) unsigned NOT NULL,
  `version` varchar(10) DEFAULT NULL,
  `retry` tinyint(4) unsigned NOT NULL DEFAULT 0,
  `scoreboard` varchar(255) DEFAULT NULL,
  `last_map` varchar(255) DEFAULT NULL,
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`steamid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- 2020-08-22 10:14:43