MERMAID := npx -y @mermaid-js/mermaid-cli
DIAGRAM_DIR := Diagrams
DIAGRAM_FLAGS := -b white -s 2

SOURCES := $(wildcard $(DIAGRAM_DIR)/*.mmd)
IMAGES := $(SOURCES:.mmd=.png)

.PHONY: diagrams
diagrams: $(IMAGES)

$(DIAGRAM_DIR)/%.png: $(DIAGRAM_DIR)/%.mmd
	$(MERMAID) -i $< -o $@ $(DIAGRAM_FLAGS)

.PHONY: clean-diagrams
clean-diagrams:
	rm -f $(IMAGES)
