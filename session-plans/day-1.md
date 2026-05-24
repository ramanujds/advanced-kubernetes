# Advanced Kubernetes Training - Day 1 Detailed Schedule (FINAL)
## Cluster Architecture, Networking & Scaling

**Date:** 25-May-2026
**Duration:** 8 hours (9:00 AM - 5:00 PM)
**Location:** Remote (Zoom + Cloud Lab Environment)
**Participants:** IT professionals (developers, DevOps, SREs, architects)
**Instructor:** Ramanuj Das, DevOps Engineer, Cloud Solutions Architect

---

## 📋 Day 1 Overview

**Theme:** Advanced Kubernetes Cluster Architecture, Production Networking & Application Scaling

**Learning Outcomes:**
By end of Day 1, participants will be able to:
- Design and implement multi-node HA Kubernetes clusters
- Configure advanced networking for microservices
- Implement service discovery and load balancing patterns
- Deploy and manage scalable applications with HPA
- Troubleshoot cluster and networking issues
- Plan for production-grade reliability

**Daily Deliverables:**
- Multi-node Kubernetes cluster with HA design
- Microservices architecture with advanced networking
- Load balancing and service discovery patterns
- HPA for autoscaling applications
- Troubleshooting tips and best practices

---

## ⏰ Day 1 Schedule at a Glance

| Time | Session | Duration | Type |
|------|---------|----------|------|
| 9:00 - 9:30 AM | **Kickstart & Brainstorm** | 30 min | Interactive |
| 9:30 - 11:00 AM | **Module 1: Cluster Architecture - Part A** | 1.5 hrs | Lecture + Lab |
| 11:00 - 11:15 AM | **Morning Break** | 15 min | Break |
| 11:15 AM - 12:30 PM | **Module 1: Cluster Architecture - Part B** | 1.25 hrs | Lecture + Lab |
| 12:30 - 1:30 PM | **Lunch Break** | 1 hr | Lunch |
| 1:30 - 3:00 PM | **Module 2: Networking in Kubernetes** | 1.5 hrs | Lecture + Lab |
| 3:00 - 3:15 PM | **Afternoon Break** | 15 min | Break |
| 3:15 - 4:45 PM | **Module 3: Scaling Kubernetes Applications** | 1.5 hrs | Lecture + Lab |
| 4:45 - 5:00 PM | **Summary & Day 2 Preview** | 15 min | Discussion |

---

## Kickstart & Brainstorm (9:00 AM - 9:30 AM)

**Duration:** 30 minutes  
**Format:** Interactive Session  
**Objective:** Understand participants and align training with their needs

### Part 1: Welcome & Course Overview (10 minutes)

### Part 2: Participant Understanding & Assessment (15 minutes)

**Go Around Table - Each Participant Shares:**

**Questions to Ask:**

1. **Background**
    - Your name, organization, and how long in IT/cloud?

2. **Kubernetes Experience**
    - How many years with Kubernetes?
    - What version do you run in production?
    - Deployed production applications?
    - Intermediate or Advanced level?

3. **Current Role**
    - Job title and team?
    - Day-to-day responsibilities with Kubernetes?
    - Admin, DevOps engineer, developer, architect, or other?

4. **Pain Points & Challenges**
    - Biggest Kubernetes challenge right now?
    - Any production incidents or outages?
    - Where do you feel knowledge gaps?
    - Scaling issues you've faced?

5. **Learning Objectives**
    - Main goal for this training?
    - Which topics interest you most?
    - What problem are you trying to solve?
    - What would success look like?

6. **Current Environment Details**
    - CNI plugin (Calico, Flannel, Weave)?
    - Managed Kubernetes (EKS, GKE, AKS) or on-premises?
    - Cluster size (number of nodes)?
    - Current monitoring and logging solution?

7. **Advanced Topic Experience**
    - Worked with StatefulSets or persistent storage?
    - Implemented network policies?
    - Set up RBAC policies?
    - Used horizontal or vertical pod autoscaling?
    - Experience with service mesh (Istio)?

**Documentation:**
- Take brief notes on each person's background
- Identify common themes in pain points
- Note expertise that can help with peer learning
- Gauge overall group knowledge level
- Flag specific topics needing extra focus

### Part 3: Set Expectations & Establish Group Norms (5 minutes)

**Training Expectations**
- Active participation in all discussions and labs
- Hands-on labs are mandatory (no passive observation)
- Ask questions freely - this is a safe learning space
- Help peers during labs (collaborative learning)
- Be patient with troubleshooting and debugging
- Provide feedback to help improve training

**Lab Environment**
- Use provided environment and cluster access
- Some labs might encounter issues - that's normal
- Report problems to instructor for group learning
- Backup cluster available if needed
- All materials provided, no additional installations needed

**Schedule & Breaks**
- We maintain the schedule strictly for fair access
- Breaks are critical - use them to recharge
- Lunch is 12:30-1:30 PM (full hour)
- Day ends at 5:00 PM sharp
- Day 2 starts at 9:00 AM (same time and location)

**Communication**
- Slack/Teams channel for async questions
- Instructor available for one-on-one help during breaks
- Recordings available after training (if applicable)
- Materials shared online for reference

---

## ⏰ Module 1: Advanced Kubernetes Cluster Architecture (9:30 AM - 12:30 PM)

**Duration:** 3 hours total (split into Part A and Part B)  
**Format:** Lecture + Lab (mixed)  
**Learning Focus:** HA design, fault tolerance, cluster management

### Part A: Cluster Architecture Fundamentals (9:30 AM - 11:00 AM)

**Duration:** 1.5 hours (45 min lecture + 45 min lab)

#### Lecture: High Availability & Cluster Design (45 minutes)

**Kubernetes Cluster Architecture Overview**
- Control plane components and their roles
    - API Server: Handles all cluster requests
    - etcd: Distributed key-value store for all cluster state
    - Scheduler: Assigns pods to nodes
    - Controller Manager: Runs cluster controllers
- Worker node components
    - kubelet: Manages containers on node
    - kube-proxy: Handles networking and services
    - Container runtime: Runs containers (Docker, containerd, etc.)
- How components communicate and interact
- Network architecture and data flow

**Single Control Plane vs. High Availability**
- What happens when single control plane fails
    - API unavailable → Can't create/modify resources
    - etcd down → No state persistence
    - Unplanned downtime implications
- Why HA is essential for production
- Multi-master/multi-control-plane architecture
    - Load balancing the API Server
    - Multiple etcd instances (Raft consensus)
    - Benefits and trade-offs
    - Typical production topology

**etcd as the Cluster Backbone**
- Role of etcd in storing all cluster state
- Raft consensus algorithm basics
- Clustering etcd for high availability
- Backup and recovery importance
- Disaster recovery from etcd failures
- Performance and scaling considerations
- Common etcd issues and troubleshooting

**Production Cluster Design Considerations**
- Network segmentation (control plane vs. worker)
- Resource allocation for control plane
- Node types and roles (control vs. worker)
- Cluster size planning and growth
- Upgrade and patch procedures
- Node lifecycle management
- Security isolation between environments
- High availability and disaster recovery
- Monitoring and observability

**Case Study: Order/Inventory Cluster Architecture**
- Show the production cluster diagram
- Explain multi-node topology
- Discuss namespace segregation strategy
- Review resource allocation
- Plan for scalability and growth
- Security boundaries and isolation

**Interactive Discussion Points**
- Ask about participant's current cluster setup
- Discuss challenges they've faced with HA
- Scaling and reliability considerations
- Trade-offs in different architectures
- Real-world failure scenarios

#### Lab 1.1: Design and Set Up HA-Ready Cluster (45 minutes)

**Lab Objective:** Create a production-like multi-node Kubernetes cluster with HA considerations

**Pre-Lab Setup - Verify Participants Have:**
- Docker Desktop or Minikube installed and running
- kubectl configured and working
- At least 8GB RAM available (or 12GB for optimal)
- Terminal/command line access
- Text editor available
- Network connectivity verified

**Lab Overview:**
Create a resilient cluster foundation with multiple nodes, proper resource allocation, and monitoring readiness

**Participant Tasks:**

**Phase 1: Cluster Creation & Verification (20 minutes)**
- Create Kubernetes cluster with 3 worker nodes
- Configure appropriate resources (memory, CPU)
- Verify all nodes reach "Ready" state
- Check control plane component status
- Review etcd health and configuration
- Document cluster information

**Phase 2: Component Understanding (15 minutes)**
- Verify API Server is accessible
- Check scheduler and controller manager status
- Review kubelet status on each node
- Understand kube-proxy role on nodes
- Check system namespace components
- Test cluster connectivity

**Phase 3: HA Readiness Assessment (10 minutes)**
- Understand what would happen if control plane failed
- Identify single points of failure
- Review backup/restore capabilities
- Plan for production readiness
- Document recovery procedures

**Expected Outcomes:**
- 3-node cluster running and healthy
- All control plane components verified
- Understanding of component roles
- HA foundation in place
- Ready for advanced configuration

**Verification Checklist:**
- ✓ All 3 nodes show "Ready" status
- ✓ Control plane components running
- ✓ etcd is accessible
- ✓ API Server responding
- ✓ Network connectivity verified
- ✓ Cluster information documented
- ✓ Ready for Module 2

**Troubleshooting Guide:**
- Insufficient resources → Allocate more RAM, use smaller cluster
- kubectl connection issues → Verify kubeconfig configuration
- Node not ready → Check system pods, network connectivity
- Component failures → Review logs, restart Docker daemon

---

### Part B: Cluster Management & Advanced Features (11:15 AM - 12:30 PM)

**Duration:** 1.25 hours (30 min lecture + 45 min lab)

#### Lecture: Cluster Management & Advanced Features (30 minutes)

**Resource Management in Kubernetes**
- Resource requests vs. limits
- CPU and memory allocation
- Node capacity planning
- Quality of Service (QoS) classes
- Eviction policies and node pressure

**Namespaces & Multi-Tenancy**
- Namespace isolation benefits
- Resource quotas per namespace
- Limit ranges for resource control
- Network policies for namespace separation
- Service discovery across namespaces

**Cluster Upgrades & Maintenance**
- Planning upgrade strategies
- Control plane upgrade procedures
- Worker node upgrade procedures
- Draining nodes safely
- Rolling updates vs. disruption
- Backup before upgrades

**Cluster Health Monitoring**
- Health check endpoints
- Readiness vs. liveness probes
- Component status verification
- Metrics collection basics
- Alerting on cluster issues

**Security at Cluster Level**
- API server security
- etcd encryption
- Network policies
- RBAC foundations
- Pod security standards

**Case Study: Order/Inventory Cluster Management**
- Resource allocation strategy
- Namespace segregation implementation
- Upgrade planning and procedures
- Health monitoring setup
- Security hardening approach

#### Lab 1.2: Configure Cluster for Production (45 minutes)

**Lab Objective:** Configure cluster with resource management, namespaces, and basic security

**Participant Tasks:**

**Phase 1: Namespace & Resource Configuration (20 minutes)**
- Create order-service namespace
- Create inventory-service namespace
- Configure resource quotas per namespace
- Set limit ranges for resource control
- Label namespaces for identification
- Understand resource allocation impact

**Phase 2: Security Foundation (15 minutes)**
- Understand RBAC concepts
- Create service accounts for services
- Configure basic access controls
- Understand network policy foundations
- Review pod security considerations
- Plan security implementation

**Phase 3: Readiness Check (10 minutes)**
- Verify namespace isolation
- Check resource quota enforcement
- Confirm service account creation
- Test connectivity between namespaces
- Document cluster configuration
- Validate for next modules

**Expected Outcomes:**
- Namespaces configured properly
- Resource quotas in place
- Service accounts created
- Security foundation laid
- Cluster ready for services

**Verification Checklist:**
- ✓ Namespaces created and labeled
- ✓ Resource quotas configured
- ✓ Service accounts exist
- ✓ Limit ranges applied
- ✓ Cross-namespace connectivity works
- ✓ Cluster configuration documented
- ✓ Ready for networking module

---

## 🍽️ Lunch Break (12:30 PM - 1:30 PM)

**Duration:** 1 hour  
**Activity:** Lunch (provided or nearby options)  
**Informal Discussion:** Optional peer networking about Kubernetes environments  
**Instructor Notes:**
- Use this time to prepare afternoon materials
- Check on participant progress
- Plan any needed customizations
- Be available for informal questions

---

## ⏰ Module 2: Networking in Kubernetes (1:30 PM - 3:00 PM)

**Duration:** 1.5 hours (40 min lecture + 50 min lab)  
**Format:** Lecture + Hands-on Lab  
**Learning Focus:** Pod networking, services, service discovery, load balancing

#### Lecture: Advanced Kubernetes Networking (40 minutes)

**Kubernetes Networking Model**
- Flat network model (why it matters)
- IP allocation and CIDR blocks
- How pods get IP addresses
- Pod-to-pod communication mechanisms
- Network namespace isolation
- Packet flow between pods on same node
- Packet flow between pods on different nodes

**Container Network Interface (CNI) Plugins**
- What CNI plugins do
- Popular CNI options (Calico, Flannel, Weave, etc.)
- CNI plugin responsibilities
- Choosing the right CNI for your use case
- Advanced CNI features (network policies, IPAM)

**Kubernetes Services**
- Why Services are needed (pod IPs are ephemeral)
- Virtual IP and how it works
- Service types and use cases:
    - ClusterIP: Internal-only service (default)
    - NodePort: External access via node port
    - LoadBalancer: Cloud provider integration
- Endpoints and automatic updates
- Service DNS naming (FQDN format)
- Service port mapping and target ports

**Service Discovery & DNS**
- CoreDNS and cluster DNS service
- DNS resolution process in Kubernetes
- Service DNS naming conventions
    - service-name.namespace.svc.cluster.local
- DNS caching and TTL implications
- Environment variables alternative
- Debugging DNS issues
- External DNS for external services

**Load Balancing & Traffic Distribution**
- How requests are routed to backend pods
- Load balancing algorithms (round-robin)
- Connection handling and persistence
- Session affinity options
- Traffic distribution across nodes
- Performance and scaling implications
- Monitoring load balancing behavior

**Advanced Networking Patterns**
- Multi-tier service architectures
- Service-to-service communication
- Namespace isolation and networking
- Ingress and Layer 7 routing concepts
- Service mesh considerations (preview)

**Case Study: Order/Inventory Microservices Communication**
- Show the service communication architecture
- How Order Service discovers Inventory Service
- Load balancing across Inventory replicas
- DNS resolution chain
- Network latency considerations
- Scaling implications

#### Lab 1.3: Deploy Services with Advanced Networking (50 minutes)

**Lab Objective:** Deploy microservices with advanced networking, load balancing, and service discovery

**Pre-Lab Preparation:**
- Review service architecture diagram
- Explain namespaces and isolation
- Discuss replica scaling
- Review expected communication flows

**Participant Tasks:**

**Phase 1: Service Deployment (20 minutes)**
- Create order-service with 3 replicas
- Create inventory-service with 3 replicas
- Create Service objects for both services
- Verify deployments rolling out
- Monitor pod readiness
- Check endpoint creation

**Phase 2: Service Discovery & Connectivity (20 minutes)**
- Verify Service endpoints auto-updated
- Test DNS resolution between services
- Confirm Order Service reaches Inventory Service
- Verify load balancing across replicas
- Test service discovery with different DNS names
- Check cross-namespace communication

**Phase 3: Advanced Testing & Validation (10 minutes)**
- Monitor request distribution
- Verify load balancing algorithms
- Test failure scenarios (pod termination)
- Confirm services recover automatically
- Validate network connectivity
- Document networking configuration

**Expected Outcomes:**
- Both services deployed with proper replicas
- Service endpoints properly configured
- Inter-service communication working
- Load balancing distributing requests
- Service discovery via DNS functional
- Understanding of networking architecture

**Verification Checklist:**
- ✓ Order service has 3 ready pods
- ✓ Inventory service has 3 ready pods
- ✓ Services have configured endpoints
- ✓ Services can communicate across namespaces
- ✓ DNS resolution working
- ✓ Load balancing distributing traffic
- ✓ Requests reaching all replicas
- ✓ Participants understand networking flow

**Troubleshooting Guide:**
- Pods stuck in Pending → Check node resources, resource quotas
- CrashLoopBackOff → Review logs, health probe configuration
- No endpoints → Verify pod labels match service selector
- Communication timeout → Check connectivity, DNS working
- Uneven load distribution → Verify load balancing algorithm

---

## ☕ Afternoon Break (3:00 PM - 3:15 PM)

**Duration:** 15 minutes  
**Activity:** Stretch, restroom, refresh  
**Informal Discussion:** Optional Q&A about networking and services  
**Instructor Notes:** Check participant progress, help anyone stuck, prepare for final module

---

## ⏰ Module 3: Scaling Kubernetes Applications (3:15 PM - 4:45 PM)

**Duration:** 1.5 hours (40 min lecture + 50 min lab)  
**Format:** Lecture + Hands-on Lab  
**Learning Focus:** HPA, VPA, autoscaling, load testing, performance

#### Lecture: Advanced Application Scaling (40 minutes)

**Kubernetes Autoscaling Architecture**
- Different autoscaling levels (pod, node, cluster)
- Autoscaling workflow and decisions
- Metrics collection and evaluation
- Scaling policies and strategies
- Cooldown periods and stabilization

**Horizontal Pod Autoscaling (HPA)**
- What HPA does and why it's important
- How HPA makes scaling decisions
- CPU and memory-based scaling
- Custom metrics for advanced scaling
- Scaling policies and behavior
- Min and max replicas configuration
- Scale up vs. scale down behavior
- HPA limitations and considerations

**Resource Requests & Limits**
- Why resource requests matter for HPA
- Setting appropriate resource requests
- Difference between requests and limits
- Quality of Service (QoS) implications
- Impact on scheduling and scaling
- Common mistakes and best practices
- Resource recommendation tools

**Performance Metrics & Monitoring**
- CPU utilization tracking
- Memory utilization tracking
- Custom application metrics
- Metrics-server for metrics collection
- Prometheus integration with HPA
- Monitoring HPA behavior
- Debugging scaling issues

**Vertical Pod Autoscaling (VPA)**
- What VPA does
- Resource recommendations
- Auto-scaling vs. recommendation modes
- Use cases for VPA
- Combining HPA and VPA

**Load Testing & Capacity Planning**
- Tools for load testing (Apache Bench, hey, etc.)
- Load patterns and testing scenarios
- Baseline performance measurement
- Scaling threshold tuning
- Performance optimization
- Cost vs. performance trade-offs

**Real-World Scaling Scenarios**
- Traffic spikes and burst handling
- Graceful scale-down
- Preventing thrashing (rapid scaling)
- Handling long-running requests
- Pod eviction and drain procedures

**Case Study: Scaling Order/Inventory Services**
- Determine appropriate resource requests
- Configure HPA for Order Service
- Configure HPA for Inventory Service
- Handle traffic patterns
- Performance under load
- Cost optimization

**Cluster-Level Scaling**
- Node autoscaling (via cloud provider)
- Pod eviction and disruption
- Descheduler for optimization
- Cluster capacity planning

#### Lab 1.4: Implement Horizontal Pod Autoscaling & Load Testing (50 minutes)

**Lab Objective:** Configure HPA and perform load testing to verify scaling behavior

**Pre-Lab Preparation:**
- Review HPA concepts
- Discuss resource request importance
- Explain load testing approach
- Review expected scaling behavior

**Participant Tasks:**

**Phase 1: Resource Configuration & HPA Setup (15 minutes)**
- Set appropriate resource requests for Order Service
- Set appropriate resource requests for Inventory Service
- Configure resource limits
- Create HPA for Order Service (min 3, max 10 replicas)
- Create HPA for Inventory Service (min 3, max 8 replicas)
- Set CPU threshold at 70% utilization
- Verify HPA objects created

**Phase 2: Metrics Verification (10 minutes)**
- Verify metrics-server is running
- Check initial CPU/memory metrics
- Confirm metrics for both services
- Monitor baseline resource usage
- Document initial state
- Verify HPA can read metrics

**Phase 3: Load Testing & Scaling Validation (20 minutes)**
- Generate load against Order Service
- Monitor HPA scaling decisions
- Watch pods scaling up
- Verify load distribution across new pods
- Monitor resource utilization
- Verify scaling threshold behavior
- Test with different load levels
- Observe scale-down behavior (after load stops)

**Phase 4: Analysis & Documentation (5 minutes)**
- Analyze scaling behavior
- Review timing of scale-up/down
- Verify performance improvements
- Document HPA configuration
- Note any issues or surprises
- Plan for next optimization

**Expected Outcomes:**
- HPA configured for both services
- Metrics being collected correctly
- Successful scale-up under load
- Successful scale-down after load
- Understanding of autoscaling mechanics
- Load testing tools working
- Performance baselines established

**Verification Checklist:**
- ✓ Resource requests set appropriately
- ✓ Resource limits configured
- ✓ HPA objects created
- ✓ Metrics-server running and collecting
- ✓ Load test tool working
- ✓ HPA scaling up under load
- ✓ Pods reaching max replica count
- ✓ HPA scaling down after load stops
- ✓ Performance improvement measurable
- ✓ Participants understand scaling

**Troubleshooting Guide:**
- HPA not scaling → Check metrics collection, resource requests set
- Metrics unavailable → Verify metrics-server deployment
- Load test not working → Check tool installation, network connectivity
- Pods evicted → Increase node resources or reduce target utilization
- Slow scaling → Check HPA scaling policies, cooldown periods

---

## 📊 Summary & Day 2 Preview (4:45 PM - 5:00 PM)

**Duration:** 15 minutes  
**Format:** Group discussion and preview

### Day 1 Recap (5 minutes)

**Module 1: Cluster Architecture**
- HA design principles for production
- Cluster components and their roles
- etcd as the cluster backbone
- Resource management and planning
- Security foundation

**Module 2: Networking**
- Pod-to-pod communication
- Service discovery and DNS
- Load balancing mechanisms
- Service types and use cases
- Microservices communication patterns

**Module 3: Scaling**
- Horizontal Pod Autoscaling
- Resource requests and limits
- Load testing and validation
- Performance monitoring
- Capacity planning

**Key Principles Emphasized**
- High availability requires planning
- Service discovery is automatic
- Scaling requires proper configuration
- Monitoring is essential
- Production patterns matter

### Daily Deliverables Verification (2 minutes)

**What You Built Today:**
- ✓ Multi-node HA cluster designed and implemented
- ✓ Order and Inventory services deployed
- ✓ Services communicating with load balancing
- ✓ Autoscaling configured and tested
- ✓ Performance validated under load
- ✓ Production-ready architecture in place

**Celebrate Success**
- Congratulate on completing Day 1
- Acknowledge challenges overcome
- Recognize collaborative problem-solving
- Highlight individual contributions

### Day 2 Preview (5 minutes)

**What's Coming Tomorrow (Days 2 & 3):**
- Persistent Storage & Stateful Applications
- Helm and Advanced Deployments
- Configuration Management
- Monitoring & Observability
- Security Best Practices
- Production Readiness
- Disaster Recovery

**Why It Matters**
- Real applications need persistent data
- Helm simplifies complex deployments
- Monitoring provides visibility
- Security protects your infrastructure
- Disaster recovery ensures business continuity

**Preparation for Next Days**
- Keep cluster running overnight (if possible)
- Reflect on today's learnings
- Think about how concepts apply to your environment
- Prepare questions for tomorrow
- Get good rest!

### Optional: Informal Discussion (remaining time)

**Open Forum**
- Any final Day 1 questions?
- How is pacing and difficulty level?
- Are concepts clear and relevant?
- Real-world scenario discussions
- Peer networking opportunities
- Congratulations on Day 1 completion

### Closing Remarks

**Important Reminders**
- Day 2 starts at 9:00 AM tomorrow
- Same location and setup
- Bring laptops fully charged
- Cluster will be reset for Day 2
- All Day 1 materials available online

**What You've Accomplished**
- Designed and built production-grade cluster
- Implemented advanced networking
- Configured autoscaling
- Validated with load testing
- Ready for production applications

**Instructor Availability**
- Available for quick help before leaving
- Slack/Teams for overnight questions
- Early arrival tomorrow if needed
- Be ready for Day 2!

---

## 📋 Instructor Checklist for Day 1

### Before Training (48 hours before):
- [ ] Test cluster access and components
- [ ] Pre-download all Docker images
- [ ] Verify network connectivity and bandwidth
- [ ] Test participant laptop access
- [ ] Prepare load testing tools
- [ ] Create Slack/Teams workspace
- [ ] Prepare backup cluster

### Day Before (Evening before):
- [ ] Set up training room and equipment
- [ ] Test projector, audio, screen
- [ ] Prepare printed materials
- [ ] Set up refreshments area
- [ ] Have backup plan ready
- [ ] Get good rest

### Morning Of (8:30 AM arrival):
- [ ] Arrive early and set up room
- [ ] Test all equipment
- [ ] Verify cluster is running
- [ ] Have coffee/water ready
- [ ] Welcome participants as they arrive
- [ ] Assist with any setup issues

### During Training:
- [ ] Start on time (9:00 AM sharp)
- [ ] Listen actively during kickstart
- [ ] Keep track of time for each session
- [ ] Monitor participant progress
- [ ] Be available for troubleshooting
- [ ] Keep energy high
- [ ] Take notes on issues
- [ ] Adjust pacing as needed

### During Labs:
- [ ] Explain objectives clearly
- [ ] Demonstrate first steps
- [ ] Circulate and check progress
- [ ] Help without giving answers
- [ ] Celebrate successes
- [ ] Document recurring issues
- [ ] Have quick fixes ready

### After Training (5:00 PM):
- [ ] Collect feedback
- [ ] Document issues
- [ ] Note which sections took longer
- [ ] Backup participant work
- [ ] Clean up materials
- [ ] Thank participants
- [ ] Make notes for Day 2 customization

### Evening (After training):
- [ ] Review feedback
- [ ] Plan Day 2 adjustments
- [ ] Verify cluster for Day 2
- [ ] Prepare additional materials if needed
- [ ] Rest well!

---

## 📝 Participant Learning Outcomes

### Module 1: Cluster Architecture
By end of this module, participants can:
- Design multi-master HA clusters
- Understand control plane components
- Plan cluster scaling and growth
- Configure resource management
- Implement namespace segregation
- Design for high availability
- Plan cluster upgrades
- Monitor cluster health

### Module 2: Networking
By end of this module, participants can:
- Deploy services with proper load balancing
- Understand service discovery mechanisms
- Configure DNS for services
- Design microservices communication
- Debug networking issues
- Plan network architecture
- Understand CNI plugins
- Monitor networking behavior

### Module 3: Scaling
By end of this module, participants can:
- Configure Horizontal Pod Autoscaling
- Set appropriate resource requests
- Load test applications
- Analyze scaling behavior
- Optimize for performance
- Plan capacity
- Monitor autoscaling
- Handle scaling edge cases

---

## 🎯 Success Criteria for Day 1

**Technical Success:**
- ✓ All participants have working clusters
- ✓ All 3 labs completed successfully
- ✓ Services deployed and communicating
- ✓ Autoscaling configured and tested
- ✓ Load testing validated
- ✓ No critical system failures

**Learning Success:**
- ✓ Participants understand core concepts
- ✓ Participants can explain architecture
- ✓ Participants can troubleshoot basic issues
- ✓ Participants know best practices
- ✓ Participants ready for Day 2

**Engagement Success:**
- ✓ Active participation throughout
- ✓ Good questions being asked
- ✓ Peer learning happening
- ✓ Positive feedback on pacing
- ✓ Interest in advanced topics

---

**END OF DAY 1**

✅ **Day 1 Complete!**

Participants now have:
- Production-grade HA cluster
- Advanced networking configured
- Autoscaling in place and tested
- Understanding of production patterns
- Ready for stateful applications (Day 2)

🎯 **Ready for Day 2?**

Please confirm:
✓ All Day 1 labs completed successfully?
✓ Participants understand core concepts?
✓ Cluster still running and healthy?
✓ Ready to move forward to Day 2?

When ready, type **"Ready for Day 2"** to create the Day 2 schedule! 🚀