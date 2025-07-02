package main

import (
	"bytes"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os/exec"
	"strconv"
	"sync"
	"time"
	"crypto/rand"
	"encoding/base64"

	"github.com/BurntSushi/toml"
	"github.com/gin-contrib/sessions"
	"github.com/gin-contrib/sessions/cookie"
	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

type ForwardingRule struct {
	Listen string `toml:"listen" json:"listen"`
	Remote string `toml:"remote" json:"remote"`
}

type Config struct {
	Network struct {
		NoTCP  bool `toml:"no_tcp"`
		UseUDP bool `toml:"use_udp"`
	} `toml:"network"`
	Endpoints []ForwardingRule `toml:"endpoints"`
}

type PanelConfig struct {
	Auth struct {
		Password string `toml:"password"`
	} `toml:"auth"`
	Server struct {
		Port int `toml:"port"`
	} `toml:"server"`
	HTTPS struct {
		Enabled  bool   `toml:"enabled"`
		CertFile string `toml:"cert_file"`
		KeyFile  string `toml:"key_file"`
	} `toml:"https"`
	SessionKey string `toml:"session_key"`
}

var (
	mu          sync.Mutex
	config      Config
	panelConfig PanelConfig
	httpsWarningShown = false
)

func LoadConfig() error {
	data, err := ioutil.ReadFile("/root/.realm/config.toml")
	if err != nil {
		return err
	}

	if _, err := toml.Decode(string(data), &config); err != nil {
		return err
	}

	return nil
}

func LoadPanelConfig() error {
	data, err := ioutil.ReadFile("./config.toml")
	if err != nil {
		return err
	}

	if _, err := toml.Decode(string(data), &panelConfig); err != nil {
		return err
	}

	return nil
}

func SaveConfig() error {
	mu.Lock()
	defer mu.Unlock()

	var buf bytes.Buffer
	encoder := toml.NewEncoder(&buf)

	if err := encoder.Encode(map[string]interface{}{"network": config.Network}); err != nil {
		return err
	}

	if len(config.Endpoints) > 0 {
		buf.WriteString("\n")
		for _, endpoint := range config.Endpoints {
			buf.WriteString("[[endpoints]]\n")
			if err := encoder.Encode(endpoint); err != nil {
				return err
			}
			buf.WriteString("\n")
		}
	}

	return ioutil.WriteFile("/root/.realm/config.toml", buf.Bytes(), 0600)
}

func AuthRequired() gin.HandlerFunc {
	return func(c *gin.Context) {
		session := sessions.Default(c)
		user := session.Get("user")
		if user == nil {
			c.Redirect(http.StatusFound, "/login")
			c.Abort()
			return
		}
		c.Next()
	}
}

func CSRFProtection() gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.Request.Method == "POST" || c.Request.Method == "DELETE" {
			session := sessions.Default(c)
			csrfToken := c.GetHeader("X-CSRF-Token")
			if csrfToken == "" || csrfToken != session.Get("csrf_token") {
				c.JSON(http.StatusForbidden, gin.H{"error": "CSRF 令牌无效"})
				c.Abort()
				return
			}
		}
		c.Next()
	}
}

func HTTPSRedirect() gin.HandlerFunc {
	return func(c *gin.Context) {
		if panelConfig.HTTPS.Enabled && c.Request.TLS == nil {
			target := "https://" + c.Request.Host + c.Request.URL.Path
			if c.Request.URL.RawQuery != "" {
				target += "?" + c.Request.URL.RawQuery
			}
			c.Redirect(http.StatusMovedPermanently, target)
			c.Abort()
			return
		}
		c.Next()
	}
}

func ValidateIPPort(input string) bool {
	parts := strings.Split(input, ":")
	if len(parts) != 2 {
		return false
	}
	ip, port := parts[0], parts[1]
	if ip == "0.0.0.0" || net.ParseIP(ip) != nil {
		if p, err := strconv.Atoi(port); err == nil && p >= 1 && p <= 65535 {
			return true
		}
	}
	return false
}

func main() {
	if err := LoadConfig(); err != nil {
		log.Fatalf("无法加载 realm 配置: %v", err)
	}

	if err := LoadPanelConfig(); err != nil {
		log.Fatalf("无法加载面板配置: %v", err)
	}

	r := gin.Default()

	if panelConfig.SessionKey == "" {
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			log.Fatalf("生成会话密钥失败: %v", err)
		}
		panelConfig.SessionKey = base64.StdEncoding.EncodeToString(key)
		// 更新 config.toml
		var buf bytes.Buffer
		toml.NewEncoder(&buf).Encode(panelConfig)
		ioutil.WriteFile("./config.toml", buf.Bytes(), 0600)
	}

	store := cookie.NewStore([]byte(panelConfig.SessionKey))
	store.Options(sessions.Options{
		MaxAge:   3600 * 2,
		Secure:   panelConfig.HTTPS.Enabled,
		HttpOnly: true,
	})
	r.Use(sessions.Sessions("realm_session", store))
	r.Use(HTTPSRedirect())
	r.Use(CSRFProtection())

	r.Static("/static", "./static")

	r.GET("/login", func(c *gin.Context) {
		session := sessions.Default(c)
		if session.Get("user") != nil {
			c.Redirect(http.StatusFound, "/")
			return
		}
		// 生成 CSRF 令牌
		csrfToken := generateCSRFToken()
		session.Set("csrf_token", csrfToken)
		session.Save()
		c.Set("csrf_token", csrfToken)
		c.File("./templates/login.html")
	})

	r.POST("/login", func(c *gin.Context) {
		var loginData struct {
			Password string `json:"password"`
		}

		if err := c.ShouldBindJSON(&loginData); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的请求"})
			return
		}

		if loginData.Password == "" || len(loginData.Password) < 8 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "密码不能为空且至少8位"})
			return
		}

		hashedPassword, err := bcrypt.GenerateFromPassword([]byte(panelConfig.Auth.Password), bcrypt.DefaultCost)
		if err != nil {
			log.Printf("密码哈希失败: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "内部错误"})
			return
		}

		if err := bcrypt.CompareHashAndPassword(hashedPassword, []byte(loginData.Password)); err == nil {
			session := sessions.Default(c)
			session.Set("user", true)
			session.Save()
			c.JSON(http.StatusOK, gin.H{"message": "登录成功"})
		} else {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "密码错误"})
		}
	})

	authorized := r.Group("/")
	authorized.Use(AuthRequired())
	{
		authorized.GET("/", func(c *gin.Context) {
			if !panelConfig.HTTPS.Enabled && !httpsWarningShown {
				c.Header("X-HTTPS-Warning", "当前未启用HTTPS，强烈建议启用HTTPS")
				httpsWarningShown = true
			}
			session := sessions.Default(c)
			csrfToken := generateCSRFToken()
			session.Set("csrf_token", csrfToken)
			session.Save()
			c.Set("csrf_token", csrfToken)
			c.File("./templates/index.html")
		})

		authorized.GET("/get_rules", func(c *gin.Context) {
			pageStr := c.Query("page")
			sizeStr := c.Query("size")
			page, err := strconv.Atoi(pageStr)
			if err != nil || page < 1 {
				page = 1
			}
			size, err := strconv.Atoi(sizeStr)
			if err != nil || size < 1 {
				size = 10
			}

			mu.Lock()
			defer mu.Unlock()

			totalCount := len(config.Endpoints)
			start := (page - 1) * size
			end := start + size
			if start >= totalCount {
				start = totalCount
			}
			if end > totalCount {
				end = totalCount
			}
			paginatedRules := config.Endpoints[start:end]

			c.JSON(200, gin.H{
				"rules": paginatedRules,
				"total": totalCount,
			})
		})

		authorized.POST("/add_rule", func(c *gin.Context) {
			var input ForwardingRule

			if err := c.ShouldBindJSON(&input); err != nil {
				c.JSON(400, gin.H{"error": "无效的输入"})
				return
			}

			if !ValidateIPPort(input.Listen) || !ValidateIPPort(input.Remote) {
				c.JSON(400, gin.H{"error": "无效的 IP 或端口"})
				return
			}

			mu.Lock()
			for _, rule := range config.Endpoints {
				if rule.Listen == input.Listen {
					mu.Unlock()
					c.JSON(400, gin.H{"error": "端口已被占用"})
					return
				}
			}
			config.Endpoints = append(config.Endpoints, input)
			mu.Unlock()

			if err := SaveConfig(); err != nil {
				c.JSON(500, gin.H{"error": "保存配置失败"})
				return
			}

			c.JSON(201, input)
		})

		authorized.DELETE("/delete_rule", func(c *gin.Context) {
			listen := c.Query("listen")
			if !ValidateIPPort(listen) {
				c.JSON(400, gin.H{"error": "无效的监听地址"})
				return
			}

			mu.Lock()
			found := false
			for i, rule := range config.Endpoints {
				if rule.Listen == listen {
					config.Endpoints = append(config.Endpoints[:i], config.Endpoints[i+1:]...)
					found = true
					break
				}
			}
			mu.Unlock()

			if err := SaveConfig(); err != nil {
				c.JSON(500, gin.H{"error": "保存转发规则失败"})
				return
			}

			if found {
				c.JSON(200, gin.H{"message": "保存转发规则成功"})
			} else {
				c.JSON(404, gin.H{"error": "未找到转发规则"})
			}
		})

		authorized.POST("/start_service", func(c *gin.Context) {
			cmd := exec.Command("systemctl", "start", "realm")
			if err := cmd.Run(); err != nil {
				log.Printf("服务启动失败: %v", err)
				c.JSON(500, gin.H{"error": "服务启动失败"})
				return
			}

			c.JSON(200, gin.H{"message": "服务启动成功"})
		})

		authorized.POST("/stop_service", func(c *gin.Context) {
			cmd := exec.Command("systemctl", "stop", "realm")
			if err := cmd.Run(); err != nil {
				log.Printf("服务停止失败: %v", err)
				c.JSON(500, gin.H{"error": "服务停止失败"})
				return
			}

			c.JSON(200, gin.H{"message": "服务停止成功"})
		})

		authorized.POST("/restart_service", func(c *gin.Context) {
			cmd := exec.Command("systemctl", "restart", "realm")
			if err := cmd.Run(); err != nil {
				log.Printf("服务重启失败: %v", err)
				c.JSON(500, gin.H{"error": "服务重启失败"})
				return
			}

			c.JSON(200, gin.H{"message": "服务重启成功"})
		})

		authorized.GET("/check_status", func(c *gin.Context) {
			cmd := exec.Command("systemctl", "is-active", "--quiet", "realm")
			err := cmd.Run()

			var status string
			if err != nil {
				if exitError, ok := err.(*exec.ExitError); ok {
					if exitError.ExitCode() == 3 {
						status = "未启用"
					} else {
						status = "未知状态"
					}
				} else {
					status = "检查失败"
				}
			} else {
				status = "启用"
			}

			c.JSON(200, gin.H{"status": status})
		})

		authorized.POST("/logout", func(c *gin.Context) {
			session := sessions.Default(c)
			session.Clear()
			session.Save()
			c.JSON(http.StatusOK, gin.H{"message": "登出成功"})
		})
	}

	port := panelConfig.Server.Port
	if port == 0 {
		port = 8081
	}

	if !panelConfig.HTTPS.Enabled {
		log.Fatalf("错误：HTTPS 必须启用")
	}

	if panelConfig.HTTPS.CertFile == "" || panelConfig.HTTPS.KeyFile == "" {
		log.Fatalf("错误：必须提供 HTTPS 证书和密钥文件")
	}

	log.Printf("服务器正在使用 HTTPS 运行，端口：%d\n", port)
	go func() {
		log.Printf("HTTP 服务器正在运行，端口：8082，用于重定向到 HTTPS\n")
		if err := http.ListenAndServe(":8082", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			target := "https://" + r.Host + r.URL.Path
			if r.URL.RawQuery != "" {
				target += "?" + r.URL.RawQuery
			}
			http.Redirect(w, r, target, http.StatusMovedPermanently)
		})); err != nil {
			log.Fatalf("HTTP 服务器错误: %v", err)
		}
	}()
	if err := r.RunTLS(fmt.Sprintf(":%d", port), panelConfig.HTTPS.CertFile, panelConfig.HTTPS.KeyFile); err != nil {
		log.Fatalf("HTTPS 服务器错误: %v", err)
	}
}

func generateCSRFToken() string {
	b := make([]byte, 16)
	rand.Read(b)
	return base64.StdEncoding.EncodeToString(b)
}
