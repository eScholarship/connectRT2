# connectRT2

## Restarting connectRT2 after modifictaions

Typically, connectRT2 will restart automatically after changes are made to any of its files (transform.rb, rest.rb, etc). However, in some cases you may need to restart it manually. These cases include:
- Your changes result in a ruby file which doesn't compile. (If this is the case, when you manually restart, you will see an error when the compile stage fails.)
- Certain git operations, e.g. the process of conflict resolution on a single file.

These are the steps to manuall restart:
* Eye stop apache connectRT2
* Run "ps -ax | grep puma" to find proc. Connected with RT2.
* Kill #### ####
* "ps -ax | grep puma" to confirm kills
* Eye start apache connectrt2

---

### Significant changes, Dec. 2023:
https://github.com/eScholarship/connectRT2/pull/51
