package cachecontent

import (
	"fmt"
	"os"
	"strconv"
)

// Getenv Load environment variable or return default value
func Getenv(key, defaultt string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return defaultt
}

// parseBoolOrFail Convert string to bool or panic if not possible
func parseBoolOrFail(value string) bool {
	parsedBool, err := strconv.ParseBool(value)
	if err != nil {
		panic(err)
	}
	return parsedBool
}

// GetBoolEnvOrDefault Parse bool value from env variable
func GetBoolEnvOrDefault(envname string, defval bool) bool {
	value := os.Getenv(envname)
	if value == "" {
		return defval
	}
	return parseBoolOrFail(value)
}

// parseIntOrFail Convert string to int or panic if not possible
func parseIntOrFail(envname, valueStr string) int {
	value, err := strconv.Atoi(valueStr)
	if err != nil {
		panic(fmt.Sprintf("Unable convert '%s' env var '%s' to int!", envname, valueStr))
	}
	return value
}

// GetIntEnvOrDefault Load int environment variable or load default
func GetIntEnvOrDefault(envname string, defval int) int {
	valueStr := os.Getenv(envname)
	if valueStr == "" {
		return defval
	}
	return parseIntOrFail(envname, valueStr)
}
