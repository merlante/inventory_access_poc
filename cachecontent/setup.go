package cachecontent

import (
	"fmt"
	"net/url"
	"strconv"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

var (
	Db                 *gorm.DB //nolint:stylecheck
	DbReadReplica      *gorm.DB //nolint:stylecheck
	OtherAdvisoryTypes []string
	AdvisoryTypes      map[int]string
	globalPgConfig     *PostgreSQLConfig
)

var Cfg = Config{}

func initDBFromEnv(pgUri string) {

	// Parse the URI
	u, err := url.Parse(pgUri)
	if err != nil {
		panic(err)
	}

	// Extract the password
	password, _ := u.User.Password()

	// Extract the port
	host := u.Hostname()
	portStr := u.Port()
	port, err := strconv.Atoi(portStr)
	if err != nil {
		panic(err)
	}

	Cfg.DBHost = host
	Cfg.DBPort = port
	Cfg.DBUser = u.User.Username()
	Cfg.DBPassword = password
	Cfg.DBName = u.Path[1:] // Skip the leading '/'

	Cfg.DBDebug = false
	Cfg.DBStatementTimeoutMs = 0
	Cfg.DBMaxConnections = 250
	Cfg.DBMaxIdleConnections = 50
	Cfg.DBMaxConnectionLifetimeS = 60
	Cfg.DBSslMode = "disable"
	Cfg.DBWorkMem = 4096
}

func InitDB(pgUri string) {
	initDBFromEnv(pgUri)
	pgConfig := loadEnvPostgreSQLConfig()
	if Db != nil && pgConfig == globalPgConfig {
		// reuse connection
		check(Db)
		return
	}
	globalPgConfig = pgConfig
	Db = openPostgreSQL(pgConfig)
	check(Db)
}

// Configure Configure database, PostgreSQL or SQLite connection
func Configure(pgUri string) {
	InitDB(pgUri)
	loadAdditionalParamsFromDB()
}

// PostgreSQLConfig PostgreSQL database config
type PostgreSQLConfig struct {
	Host        string
	Port        int
	User        string
	Database    string
	Passwd      string
	SSLMode     string
	SSLRootCert string
	Debug       bool

	// Additional params.
	StatementTimeoutMs     int // https://www.postgresql.org/docs/10/runtime-config-client.html
	MaxConnections         int
	MaxIdleConnections     int
	MaxConnectionLifetimeS int
}

func createGormConfig(debug bool) *gorm.Config {
	cfg := gorm.Config{}
	if !debug {
		cfg.Logger = logger.Default.LogMode(logger.Silent) // Allow "Slow SQL" warnings on debug mode only.
	}
	return &cfg
}

// open database connection
func openPostgreSQL(dbConfig *PostgreSQLConfig) *gorm.DB {
	connectString := dataSourceName(dbConfig)
	db, err := gorm.Open(postgres.Open(connectString), createGormConfig(dbConfig.Debug))
	if err != nil {
		panic(err)
	}

	if dbConfig.Debug {
		db = db.Debug()
	}
	sqlDB, err := db.DB()
	if err != nil {
		panic(err)
	}

	sqlDB.SetMaxOpenConns(dbConfig.MaxConnections)
	sqlDB.SetMaxIdleConns(dbConfig.MaxIdleConnections)
	sqlDB.SetConnMaxLifetime(time.Duration(dbConfig.MaxConnectionLifetimeS) * time.Second)
	return db
}

// chcek if database connection works
func check(db *gorm.DB) {
	sqlDB, err := db.DB()
	if err != nil {
		panic(err)
	}

	err = sqlDB.Ping()
	if err != nil {
		panic(err)
	}
}

// load database config from environment vars using inserted prefix
func loadEnvPostgreSQLConfig() *PostgreSQLConfig {
	host := Cfg.DBHost
	port := Cfg.DBPort

	config := PostgreSQLConfig{
		User:                   Cfg.DBUser,
		Host:                   host,
		Port:                   port,
		Database:               Cfg.DBName,
		Passwd:                 Cfg.DBPassword,
		SSLMode:                Cfg.DBSslMode,
		SSLRootCert:            Cfg.DBSslRootCert,
		Debug:                  Cfg.DBDebug,
		StatementTimeoutMs:     Cfg.DBStatementTimeoutMs,
		MaxConnections:         Cfg.DBMaxConnections,
		MaxIdleConnections:     Cfg.DBMaxIdleConnections,
		MaxConnectionLifetimeS: Cfg.DBMaxConnectionLifetimeS,
	}
	return &config
}

// create "data source" config string needed for database connection opening
func dataSourceName(dbConfig *PostgreSQLConfig) string {
	dbsource := fmt.Sprintf("host=%s port=%d user=%s dbname=%s password=%s sslmode=%s statement_timeout=%d",
		dbConfig.Host, dbConfig.Port, dbConfig.User, dbConfig.Database, dbConfig.Passwd, dbConfig.SSLMode,
		dbConfig.StatementTimeoutMs)
	return dbsource
}

func loadAdditionalParamsFromDB() {
	// Load OtherAdvisoryTypes list
	err := Db.Table("advisory_type").
		Where("name NOT IN ('enhancement', 'bugfix', 'security')").
		Order("name").
		Pluck("name", &OtherAdvisoryTypes).Error
	fmt.Println("other_advisory_types", OtherAdvisoryTypes, "Other advisory types loaded from DB")
	if err != nil {
		panic(err)
	}

	// Load AdvisoryTypes
	var types []AdvisoryType

	err = Db.Table("advisory_type").
		Select("id, name").
		Scan(&types).Error
	fmt.Println("advisory_types", types, "Advisory types loaded from DB")
	if err != nil {
		panic(err)
	}

	AdvisoryTypes = make(map[int]string)
	for _, at := range types {
		AdvisoryTypes[at.ID] = at.Name
	}
}
