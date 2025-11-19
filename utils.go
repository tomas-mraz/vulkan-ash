package main

import (
	"bytes"
)

const (
	end     = "\x00"
	endChar = '\x00'
)

func GetCString(slice []byte) string {
	return string(bytes.TrimRight(slice, "\x00"))
}

func MakeCString(s string) string {
	if len(s) == 0 {
		return end
	}
	if s[len(s)-1] != endChar {
		return s + end
	}
	return s
}
