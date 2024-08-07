-- SPDX-FileCopyrightText: 2024 DS
--
-- SPDX-License-Identifier: Apache-2.0

ignore = {}

read_globals = {
	"minetest",
	"vector",
	math = {fields = {"sign"}},

	"creative",
	"player_api",
}

globals = {
	player_api = {fields = {"player_attached"}}
}
